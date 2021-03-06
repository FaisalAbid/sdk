// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'optimizers.dart' show Pass, ParentVisitor;

import '../constants/constant_system.dart';
import '../constants/expressions.dart';
import '../resolution/operators.dart';
import '../constants/values.dart';
import '../dart_types.dart' as types;
import '../dart2jslib.dart' as dart2js;
import '../tree/tree.dart' show LiteralDartString;
import 'cps_ir_nodes.dart';
import '../types/types.dart' show TypeMask, TypesTask;
import '../types/constants.dart' show computeTypeMask;
import '../elements/elements.dart' show ClassElement, Element, Entity,
    FieldElement, FunctionElement, ParameterElement;
import '../dart2jslib.dart' show ClassWorld;
import '../universe/universe.dart';

abstract class TypeSystem<T> {
  T get dynamicType;
  T get typeType;
  T get functionType;
  T get boolType;
  T get intType;
  T get stringType;
  T get listType;
  T get mapType;

  T getReturnType(FunctionElement element);
  T getSelectorReturnType(Selector selector);
  T getParameterType(ParameterElement element);
  T join(T a, T b);
  T typeOf(ConstantValue constant);

  /// True if all values satisfying [type] are booleans (null is not a boolean).
  bool isDefinitelyBool(T type);
}

class UnitTypeSystem implements TypeSystem<String> {
  static const String UNIT = 'unit';

  get boolType => UNIT;
  get dynamicType => UNIT;
  get functionType => UNIT;
  get intType => UNIT;
  get listType => UNIT;
  get mapType => UNIT;
  get stringType => UNIT;
  get typeType => UNIT;

  getParameterType(_) => UNIT;
  getReturnType(_) => UNIT;
  getSelectorReturnType(_) => UNIT;
  join(a, b) => UNIT;
  typeOf(_) => UNIT;

  bool isDefinitelyBool(_) => false;
}

class TypeMaskSystem implements TypeSystem<TypeMask> {
  final TypesTask inferrer;
  final ClassWorld classWorld;

  TypeMask get dynamicType => inferrer.dynamicType;
  TypeMask get typeType => inferrer.typeType;
  TypeMask get functionType => inferrer.functionType;
  TypeMask get boolType => inferrer.boolType;
  TypeMask get intType => inferrer.intType;
  TypeMask get stringType => inferrer.stringType;
  TypeMask get listType => inferrer.listType;
  TypeMask get mapType => inferrer.mapType;

  // TODO(karlklose): remove compiler here.
  TypeMaskSystem(dart2js.Compiler compiler)
    : inferrer = compiler.typesTask,
      classWorld = compiler.world;

  TypeMask getParameterType(ParameterElement parameter) {
    return inferrer.getGuaranteedTypeOfElement(parameter);
  }

  TypeMask getReturnType(FunctionElement function) {
    return inferrer.getGuaranteedReturnTypeOfElement(function);
  }

  TypeMask getSelectorReturnType(Selector selector) {
    return inferrer.getGuaranteedTypeOfSelector(selector);
  }

  @override
  TypeMask join(TypeMask a, TypeMask b) {
    return a.union(b, classWorld);
  }

  @override
  TypeMask typeOf(ConstantValue constant) {
    return computeTypeMask(inferrer.compiler, constant);
  }

  bool isDefinitelyBool(TypeMask t) {
    return t.containsOnlyBool(classWorld) && !t.isNullable;
  }
}

/**
 * Propagates types (including value types for constants) throughout the IR, and
 * replaces branches with fixed jumps as well as side-effect free expressions
 * with known constant results.
 *
 * Should be followed by the [ShrinkingReducer] pass.
 *
 * Implemented according to 'Constant Propagation with Conditional Branches'
 * by Wegman, Zadeck.
 */
class TypePropagator<T> extends Pass {
  String get passName => 'Sparse constant propagation';

  final types.DartTypes _dartTypes;

  // The constant system is used for evaluation of expressions with constant
  // arguments.
  final ConstantSystem _constantSystem;
  final TypeSystem _typeSystem;
  final dart2js.InternalErrorFunction _internalError;
  final Map<Node, _AbstractValue> _types;

  TypePropagator(this._dartTypes,
                 this._constantSystem,
                 this._typeSystem,
                 this._internalError)
      : _types = <Node, _AbstractValue>{};

  @override
  void rewrite(RootNode root) {
    if (root.isEmpty) return;

    // Set all parent pointers.
    new ParentVisitor().visit(root);

    // Analyze. In this phase, the entire term is analyzed for reachability
    // and the abstract value of each expression.
    _TypePropagationVisitor<T> analyzer = new _TypePropagationVisitor<T>(
        _constantSystem,
        _typeSystem,
        _types,
        _internalError,
        _dartTypes);

    analyzer.analyze(root);

    // Transform. Uses the data acquired in the previous analysis phase to
    // replace branches with fixed targets and side-effect-free expressions
    // with constant results.
    _TransformingVisitor<T> transformer = new _TransformingVisitor<T>(
        analyzer.reachableNodes, analyzer.values, _internalError, _typeSystem);
    transformer.transform(root);
  }

  getType(Node node) => _types[node];
}

/**
 * Uses the information from a preceding analysis pass in order to perform the
 * actual transformations on the CPS graph.
 */
class _TransformingVisitor<T> extends RecursiveVisitor {
  final Set<Node> reachable;
  final Map<Node, _AbstractValue> values;
  final TypeSystem<T> typeSystem;

  final dart2js.InternalErrorFunction internalError;

  _TransformingVisitor(this.reachable,
                       this.values,
                       this.internalError,
                       this.typeSystem);

  void transform(RootNode root) {
    visit(root);
  }

  /// Given an expression with a known constant result and a continuation,
  /// replaces the expression by a new LetPrim / InvokeContinuation construct.
  /// `unlink` is a closure responsible for unlinking all removed references.
  LetPrim constifyExpression(Expression node,
                             Continuation continuation,
                             void unlink()) {
    _AbstractValue value = values[node];
    if (value == null || !value.isConstant) {
      return null;
    }

    assert(continuation.parameters.length == 1);

    // Set up the replacement structure.
    PrimitiveConstantValue primitiveConstant = value.constant;
    ConstantExpression constExp =
        const ConstantExpressionCreator().convert(primitiveConstant);
    Constant constant = new Constant(constExp);
    LetPrim letPrim = new LetPrim(constant);
    InvokeContinuation invoke =
        new InvokeContinuation(continuation, <Primitive>[constant]);

    invoke.parent = constant.parent = letPrim;
    letPrim.body = invoke;

    // Replace the method invocation.

    InteriorNode parent = node.parent;
    letPrim.parent = parent;
    parent.body = letPrim;

    unlink();

    return letPrim;
  }

  // A branch can be eliminated and replaced by an invocation if only one of
  // the possible continuations is reachable. Removal often leads to both dead
  // primitives (the condition variable) and dead continuations (the unreachable
  // branch), which are both removed by the shrinking reductions pass.
  //
  // (Branch (IsTrue true) k0 k1) -> (InvokeContinuation k0)
  void visitBranch(Branch node) {
    bool trueReachable  = reachable.contains(node.trueContinuation.definition);
    bool falseReachable = reachable.contains(node.falseContinuation.definition);
    bool bothReachable  = (trueReachable && falseReachable);
    bool noneReachable  = !(trueReachable || falseReachable);

    if (bothReachable || noneReachable) {
      // Nothing to do, shrinking reductions take care of the unreachable case.
      super.visitBranch(node);
      return;
    }

    Continuation successor = (trueReachable) ?
        node.trueContinuation.definition : node.falseContinuation.definition;

    // Replace the branch by a continuation invocation.

    assert(successor.parameters.isEmpty);
    InvokeContinuation invoke =
        new InvokeContinuation(successor, <Primitive>[]);

    InteriorNode parent = node.parent;
    invoke.parent = parent;
    parent.body = invoke;

    // Unlink all removed references.

    node.trueContinuation.unlink();
    node.falseContinuation.unlink();
    IsTrue isTrue = node.condition;
    isTrue.value.unlink();

    visitInvokeContinuation(invoke);
  }

  // Side-effect free method calls with constant results can be replaced by
  // a LetPrim / InvokeContinuation pair. May lead to dead primitives which
  // are removed by the shrinking reductions pass.
  //
  // (InvokeMethod v0 == v1 k0)
  // -> (assuming the result is a constant `true`)
  // (LetPrim v2 (Constant true))
  // (InvokeContinuation k0 v2)
  void visitInvokeMethod(InvokeMethod node) {
    Continuation cont = node.continuation.definition;
    LetPrim letPrim = constifyExpression(node, cont, () {
      node.receiver.unlink();
      node.continuation.unlink();
      node.arguments.forEach((Reference ref) => ref.unlink());
    });

    if (letPrim == null) {
      super.visitInvokeMethod(node);
    } else {
      visitLetPrim(letPrim);
    }
  }

  // See [visitInvokeMethod].
  void visitConcatenateStrings(ConcatenateStrings node) {
    Continuation cont = node.continuation.definition;
    LetPrim letPrim = constifyExpression(node, cont, () {
      node.continuation.unlink();
      node.arguments.forEach((Reference ref) => ref.unlink());
    });

    if (letPrim == null) {
      super.visitConcatenateStrings(node);
    } else {
      visitLetPrim(letPrim);
    }
  }

  // See [visitInvokeMethod].
  void visitTypeOperator(TypeOperator node) {
    Continuation cont = node.continuation.definition;
    LetPrim letPrim = constifyExpression(node, cont, () {
      node.receiver.unlink();
      node.continuation.unlink();
    });

    if (letPrim == null) {
      super.visitTypeOperator(node);
    } else {
      visitLetPrim(letPrim);
    }
  }

  _AbstractValue<T> getValue(Primitive primitive) {
    _AbstractValue<T> value = values[primitive];
    return value == null ? new _AbstractValue.nothing() : value;
  }

  void visitIdentical(Identical node) {
    Primitive left = node.left.definition;
    Primitive right = node.right.definition;
    _AbstractValue<T> leftValue = getValue(left);
    _AbstractValue<T> rightValue = getValue(right);
    // Replace identical(x, true) by x when x is known to be a boolean.
    if (leftValue.isDefinitelyBool(typeSystem) &&
        rightValue.isConstant &&
        rightValue.constant.isTrue) {
      left.substituteFor(node);
    }
  }
}

/**
 * Runs an analysis pass on the given function definition in order to detect
 * const-ness as well as reachability, both of which are used in the subsequent
 * transformation pass.
 */
class _TypePropagationVisitor<T> implements Visitor {
  // The node worklist stores nodes that are both reachable and need to be
  // processed, but have not been processed yet. Using a worklist avoids deep
  // recursion.
  // The node worklist and the reachable set operate in concert: nodes are
  // only ever added to the worklist when they have not yet been marked as
  // reachable, and adding a node to the worklist is always followed by marking
  // it reachable.
  // TODO(jgruber): Storing reachability per-edge instead of per-node would
  // allow for further optimizations.
  final List<Node> nodeWorklist = <Node>[];
  final Set<Node> reachableNodes = new Set<Node>();

  // The definition workset stores all definitions which need to be reprocessed
  // since their lattice value has changed.
  final Set<Definition> defWorkset = new Set<Definition>();

  final ConstantSystem constantSystem;
  final TypeSystem<T> typeSystem;
  final dart2js.InternalErrorFunction internalError;
  final types.DartTypes _dartTypes;

  _AbstractValue<T> nothing = new _AbstractValue.nothing();

  _AbstractValue<T> nonConstant([T type]) {
    if (type == null) {
      type = typeSystem.dynamicType;
    }
    return new _AbstractValue<T>.nonConstant(type);
  }

  _AbstractValue<T> constantValue(ConstantValue constant, T type) {
    return new _AbstractValue<T>.constantValue(constant, type);
  }

  // Stores the current lattice value for nodes. Note that it contains not only
  // definitions as keys, but also expressions such as method invokes.
  // Access through [getValue] and [setValue].
  final Map<Node, _AbstractValue<T>> values;

  _TypePropagationVisitor(this.constantSystem,
                          TypeSystem typeSystem,
                          this.values,
                          this.internalError,
                          this._dartTypes)
      : this.typeSystem = typeSystem;

  void analyze(RootNode root) {
    reachableNodes.clear();
    defWorkset.clear();
    nodeWorklist.clear();

    // Initially, only the root node is reachable.
    setReachable(root);

    while (true) {
      if (nodeWorklist.isNotEmpty) {
        // Process a new reachable expression.
        Node node = nodeWorklist.removeLast();
        visit(node);
      } else if (defWorkset.isNotEmpty) {
        // Process all usages of a changed definition.
        Definition def = defWorkset.first;
        defWorkset.remove(def);

        // Visit all uses of this definition. This might add new entries to
        // [nodeWorklist], for example by visiting a newly-constant usage within
        // a branch node.
        for (Reference ref = def.firstRef; ref != null; ref = ref.next) {
          visit(ref.parent);
        }
      } else {
        break;  // Both worklists empty.
      }
    }
  }

  /// If the passed node is not yet reachable, mark it reachable and add it
  /// to the work list.
  void setReachable(Node node) {
    if (!reachableNodes.contains(node)) {
      reachableNodes.add(node);
      nodeWorklist.add(node);
    }
  }

  /// Returns the lattice value corresponding to [node], defaulting to nothing.
  ///
  /// Never returns null.
  _AbstractValue<T> getValue(Node node) {
    _AbstractValue<T> value = values[node];
    return (value == null) ? nothing : value;
  }

  /// Joins the passed lattice [updateValue] to the current value of [node],
  /// and adds it to the definition work set if it has changed and [node] is
  /// a definition.
  void setValue(Node node, _AbstractValue<T> updateValue) {
    _AbstractValue<T> oldValue = getValue(node);
    _AbstractValue<T> newValue = updateValue.join(oldValue, typeSystem);
    if (oldValue == newValue) {
      return;
    }

    // Values may only move in the direction NOTHING -> CONSTANT -> NONCONST.
    assert(newValue.kind >= oldValue.kind);

    values[node] = newValue;
    if (node is Definition) {
      defWorkset.add(node);
    }
  }

  // -------------------------- Visitor overrides ------------------------------
  void visit(Node node) { node.accept(this); }

  void visitFieldDefinition(FieldDefinition node) {
    setReachable(node.body);
  }

  void visitFunctionDefinition(FunctionDefinition node) {
    if (node.thisParameter != null) {
      setValue(node.thisParameter, nonConstant());
    }
    node.parameters.forEach(visit);
    setReachable(node.body);
  }

  void visitConstructorDefinition(ConstructorDefinition node) {
    node.parameters.forEach(visit);
    node.initializers.forEach(visit);
    setReachable(node.body);
  }

  void visitBody(Body node) {
    setReachable(node.body);
  }

  void visitFieldInitializer(FieldInitializer node) {
    setReachable(node.body);
  }

  void visitSuperInitializer(SuperInitializer node) {
    node.arguments.forEach(setReachable);
  }

  // Expressions.

  void visitLetPrim(LetPrim node) {
    visit(node.primitive); // No reason to delay visits to primitives.
    setReachable(node.body);
  }

  void visitLetCont(LetCont node) {
    // The continuation is only marked as reachable on use.
    setReachable(node.body);
  }

  void visitLetHandler(LetHandler node) {
    setReachable(node.body);
    // The handler is assumed to be reachable (we could instead treat it as
    // unreachable unless we find something reachable that might throw in the
    // body --- it's not clear if we want to do that here or in some other
    // pass).  The handler parameters are assumed to be unknown.
    //
    // TODO(kmillikin): we should set the type of the exception and stack
    // trace here.  The way we do that depends on how we handle 'on T' catch
    // clauses.
    setReachable(node.handler);
    for (Parameter param in node.handler.parameters) {
      setValue(param, nonConstant());
    }
  }

  void visitLetMutable(LetMutable node) {
    setValue(node.variable, getValue(node.value.definition));
    setReachable(node.body);
  }

  void visitInvokeStatic(InvokeStatic node) {
    Continuation cont = node.continuation.definition;
    setReachable(cont);

    assert(cont.parameters.length == 1);
    Parameter returnValue = cont.parameters[0];
    Entity target = node.target;
    T returnType = target is FieldElement
        ? typeSystem.dynamicType
        : typeSystem.getReturnType(node.target);
    setValue(returnValue, nonConstant(returnType));
  }

  void visitInvokeContinuation(InvokeContinuation node) {
    Continuation cont = node.continuation.definition;
    setReachable(cont);

    // Forward the constant status of all continuation invokes to the
    // continuation. Note that this is effectively a phi node in SSA terms.
    for (int i = 0; i < node.arguments.length; i++) {
      Definition def = node.arguments[i].definition;
      _AbstractValue<T> cell = getValue(def);
      setValue(cont.parameters[i], cell);
    }
  }

  void visitInvokeMethod(InvokeMethod node) {
    Continuation cont = node.continuation.definition;
    setReachable(cont);

    /// Sets the value of both the current node and the target continuation
    /// parameter.
    void setValues(_AbstractValue<T> updateValue) {
      setValue(node, updateValue);
      Parameter returnValue = cont.parameters[0];
      setValue(returnValue, updateValue);
    }

    _AbstractValue<T> lhs = getValue(node.receiver.definition);
    if (lhs.isNothing) {
      return;  // And come back later.
    } else if (lhs.isNonConst) {
      setValues(nonConstant(typeSystem.getSelectorReturnType(node.selector)));
      return;
    } else if (!node.selector.isOperator) {
      // TODO(jgruber): Handle known methods on constants such as String.length.
      setValues(nonConstant());
      return;
    }

    // Calculate the resulting constant if possible.
    ConstantValue result;
    String opname = node.selector.name;
    if (node.selector.argumentCount == 0) {
      // Unary operator.

      if (opname == "unary-") {
        opname = "-";
      }
      UnaryOperation operation = constantSystem.lookupUnary(
          UnaryOperator.parse(opname));
      if (operation != null) {
        result = operation.fold(lhs.constant);
      }
    } else if (node.selector.argumentCount == 1) {
      // Binary operator.

      _AbstractValue<T> rhs = getValue(node.arguments[0].definition);
      if (!rhs.isConstant) {
        setValues(nonConstant());
        return;
      }

      BinaryOperation operation = constantSystem.lookupBinary(
          BinaryOperator.parse(opname));
      if (operation != null) {
        result = operation.fold(lhs.constant, rhs.constant);
      }
    }

    // Update value of the continuation parameter. Again, this is effectively
    // a phi.
    if (result == null) {
      setValues(nonConstant());
    } else {
      T type = typeSystem.typeOf(result);
      setValues(constantValue(result, type));
    }
   }

  void visitInvokeMethodDirectly(InvokeMethodDirectly node) {
    Continuation cont = node.continuation.definition;
    setReachable(cont);

    assert(cont.parameters.length == 1);
    Parameter returnValue = cont.parameters[0];
    // TODO(karlklose): lookup the function and get ites return type.
    setValue(returnValue, nonConstant());
  }

  void visitInvokeConstructor(InvokeConstructor node) {
    Continuation cont = node.continuation.definition;
    setReachable(cont);

    assert(cont.parameters.length == 1);
    Parameter returnValue = cont.parameters[0];
    setValue(returnValue, nonConstant());
  }

  void visitConcatenateStrings(ConcatenateStrings node) {
    Continuation cont = node.continuation.definition;
    setReachable(cont);

    void setValues(_AbstractValue<T> updateValue) {
      setValue(node, updateValue);
      Parameter returnValue = cont.parameters[0];
      setValue(returnValue, updateValue);
    }

    // TODO(jgruber): Currently we only optimize if all arguments are string
    // constants, but we could also handle cases such as "foo${42}".
    bool allStringConstants = node.arguments.every((Reference ref) {
      if (!(ref.definition is Constant)) {
        return false;
      }
      Constant constant = ref.definition;
      return constant != null && constant.value.isString;
    });

    T type = typeSystem.stringType;
    assert(cont.parameters.length == 1);
    if (allStringConstants) {
      // All constant, we can concatenate ourselves.
      Iterable<String> allStrings = node.arguments.map((Reference ref) {
        Constant constant = ref.definition;
        StringConstantValue stringConstant = constant.value;
        return stringConstant.primitiveValue.slowToString();
      });
      LiteralDartString dartString = new LiteralDartString(allStrings.join());
      ConstantValue constant = new StringConstantValue(dartString);
      setValues(constantValue(constant, type));
    } else {
      setValues(nonConstant(type));
    }
  }

  void visitThrow(Throw node) {
  }

  void visitRethrow(Rethrow node) {
  }

  void visitNonTailThrow(NonTailThrow node) {
    internalError(null, 'found non-tail throw after they were eliminated');
  }

  void visitBranch(Branch node) {
    IsTrue isTrue = node.condition;
    _AbstractValue<T> conditionCell = getValue(isTrue.value.definition);

    if (conditionCell.isNothing) {
      return;  // And come back later.
    } else if (conditionCell.isNonConst) {
      setReachable(node.trueContinuation.definition);
      setReachable(node.falseContinuation.definition);
    } else if (conditionCell.isConstant && !conditionCell.constant.isBool) {
      // Treat non-bool constants in condition as non-const since they result
      // in type errors in checked mode.
      // TODO(jgruber): Default to false in unchecked mode.
      setReachable(node.trueContinuation.definition);
      setReachable(node.falseContinuation.definition);
      setValue(isTrue.value.definition, nonConstant(typeSystem.boolType));
    } else if (conditionCell.isConstant && conditionCell.constant.isBool) {
      BoolConstantValue boolConstant = conditionCell.constant;
      setReachable((boolConstant.isTrue) ?
          node.trueContinuation.definition : node.falseContinuation.definition);
    }
  }

  void visitTypeOperator(TypeOperator node) {
    Continuation cont = node.continuation.definition;
    setReachable(cont);

    void setValues(_AbstractValue<T> updateValue) {
      setValue(node, updateValue);
      Parameter returnValue = cont.parameters[0];
      setValue(returnValue, updateValue);
    }

    if (node.isTypeCast) {
      // TODO(jgruber): Add support for `as` casts.
      setValues(nonConstant());
    }

    _AbstractValue<T> cell = getValue(node.receiver.definition);
    if (cell.isNothing) {
      return;  // And come back later.
    } else if (cell.isNonConst) {
      setValues(nonConstant(cell.type));
    } else if (node.type.kind == types.TypeKind.INTERFACE) {
      // Receiver is a constant, perform is-checks at compile-time.

      types.InterfaceType checkedType = node.type;
      ConstantValue constant = cell.constant;
      // TODO(karlklose): remove call to computeType.
      types.DartType constantType = constant.getType(_dartTypes.coreTypes);

      T type = typeSystem.boolType;
      _AbstractValue<T> result;
      if (constant.isNull &&
          checkedType != _dartTypes.coreTypes.nullType &&
          checkedType != _dartTypes.coreTypes.objectType) {
        // `(null is Type)` is true iff Type is in { Null, Object }.
        result = constantValue(new FalseConstantValue(), type);
      } else {
        // Otherwise, perform a standard subtype check.
        result = constantValue(
            constantSystem.isSubtype(_dartTypes, constantType, checkedType)
            ? new TrueConstantValue()
            : new FalseConstantValue(),
            type);
      }
      setValues(result);
    }
  }

  void visitSetMutableVariable(SetMutableVariable node) {
    setValue(node.variable.definition, getValue(node.value.definition));
    setReachable(node.body);
  }

  void visitDeclareFunction(DeclareFunction node) {
    setReachable(node.definition);
    setReachable(node.body);
  }

  // Definitions.
  void visitLiteralList(LiteralList node) {
    // Constant lists are translated into (Constant ListConstant(...)) IR nodes,
    // and thus LiteralList nodes are NonConst.
    setValue(node, nonConstant(typeSystem.listType));
  }

  void visitLiteralMap(LiteralMap node) {
    // Constant maps are translated into (Constant MapConstant(...)) IR nodes,
    // and thus LiteralMap nodes are NonConst.
    setValue(node, nonConstant(typeSystem.mapType));
  }

  void visitConstant(Constant node) {
    ConstantValue value = node.value;
    setValue(node, constantValue(value, typeSystem.typeOf(value)));
  }

  void visitReifyTypeVar(ReifyTypeVar node) {
    setValue(node, nonConstant(typeSystem.typeType));
  }

  void visitCreateFunction(CreateFunction node) {
    setReachable(node.definition);
    ConstantValue constant =
        new FunctionConstantValue(node.definition.element);
    setValue(node, constantValue(constant, typeSystem.functionType));
  }

  void visitGetMutableVariable(GetMutableVariable node) {
    setValue(node, getValue(node.variable.definition));
  }

  void visitMutableVariable(MutableVariable node) {
    // [MutableVariable]s are bound either as parameters to
    // [FunctionDefinition]s, by [LetMutable], or by [DeclareFunction].
    if (node.parent is RootNode) {
      // Just like immutable parameters, the values of mutable parameters are
      // never constant.
      // TODO(karlklose): remove reference to the element model.
      Entity source = node.hint;
      T type = (source is ParameterElement)
          ? typeSystem.getParameterType(source)
          : typeSystem.dynamicType;
      setValue(node, nonConstant(type));
    } else if (node.parent is LetMutable || node.parent is DeclareFunction) {
      // Mutable values bound by LetMutable or DeclareFunction could have
      // known values.
    } else {
      internalError(node.hint, "Unexpected parent of MutableVariable");
    }
  }

  void visitParameter(Parameter node) {
    Entity source = node.hint;
    // TODO(karlklose): remove reference to the element model.
    T type = (source is ParameterElement)
        ? typeSystem.getParameterType(source)
        : typeSystem.dynamicType;
    if (node.parent is RootNode) {
      // Functions may escape and thus their parameters must be non-constant.
      setValue(node, nonConstant(type));
    } else if (node.parent is Continuation) {
      // Continuations on the other hand are local, and parameters can have
      // some other abstract value than non-constant.
    } else {
      internalError(node.hint, "Unexpected parent of Parameter: ${node.parent}");
    }
  }

  void visitContinuation(Continuation node) {
    node.parameters.forEach(visit);

    if (node.body != null) {
      setReachable(node.body);
    }
  }

  // Conditions.

  void visitIsTrue(IsTrue node) {
    Branch branch = node.parent;
    visitBranch(branch);
  }

  // JavaScript specific nodes.

  void visitIdentical(Identical node) {
    _AbstractValue<T> leftConst = getValue(node.left.definition);
    _AbstractValue<T> rightConst = getValue(node.right.definition);
    ConstantValue leftValue = leftConst.constant;
    ConstantValue rightValue = rightConst.constant;
    if (leftConst.isNothing || rightConst.isNothing) {
      // Come back later.
      return;
    } else if (!leftConst.isConstant || !rightConst.isConstant) {
      T leftType = leftConst.type;
      T rightType = rightConst.type;
      setValue(node, nonConstant(typeSystem.boolType));
    } else if (leftValue.isPrimitive && rightValue.isPrimitive) {
      assert(leftConst.isConstant && rightConst.isConstant);
      PrimitiveConstantValue left = leftValue;
      PrimitiveConstantValue right = rightValue;
      ConstantValue result =
          new BoolConstantValue(left.primitiveValue == right.primitiveValue);
      setValue(node, constantValue(result, typeSystem.boolType));
    }
  }

  void visitInterceptor(Interceptor node) {
    setReachable(node.input.definition);
  }

  void visitGetField(GetField node) {
    setValue(node, nonConstant());
  }

  void visitSetField(SetField node) {
    setReachable(node.body);
  }

  void visitGetStatic(GetStatic node) {
    setValue(node, nonConstant());
  }

  void visitSetStatic(SetStatic node) {
    setReachable(node.body);
  }

  void visitCreateBox(CreateBox node) {
    setValue(node, nonConstant());
  }

  void visitCreateInstance(CreateInstance node) {
    setValue(node, nonConstant());
  }

  void visitReifyRuntimeType(ReifyRuntimeType node) {
    setValue(node, nonConstant(typeSystem.typeType));
  }

  void visitReadTypeVariable(ReadTypeVariable node) {
    // TODO(karlklose): come up with a type marker for JS entities or switch to
    // real constants of type [Type].
    setValue(node, nonConstant());
  }

  @override
  visitTypeExpression(TypeExpression node) {
    // TODO(karlklose): come up with a type marker for JS entities or switch to
    // real constants of type [Type].
    setValue(node, nonConstant());
  }

  void visitCreateInvocationMirror(CreateInvocationMirror node) {
    setValue(node, nonConstant());
  }
}

/// Represents the abstract value of a primitive value at some point in the
/// program. Abstract values of all kinds have a type [T].
///
/// The different kinds of abstract values represents the knowledge about the
/// constness of the value:
///   NOTHING:  cannot have any value
///   CONSTANT: is a constant. The value is stored in the [constant] field,
///             and the type of the constant is in the [type] field.
///   NONCONST: not a constant, but [type] may hold some information.
class _AbstractValue<T> {
  static const int NOTHING  = 0;
  static const int CONSTANT = 1;
  static const int NONCONST = 2;

  final int kind;
  final ConstantValue constant;
  final T type;

  _AbstractValue._internal(this.kind, this.constant, this.type) {
    assert(kind != CONSTANT || constant != null);
  }

  _AbstractValue.nothing()
      : this._internal(NOTHING, null, null);

  _AbstractValue.constantValue(ConstantValue constant, T type)
      : this._internal(CONSTANT, constant, type);

  _AbstractValue.nonConstant(T type)
      : this._internal(NONCONST, null, type);

  bool get isNothing  => (kind == NOTHING);
  bool get isConstant => (kind == CONSTANT);
  bool get isNonConst => (kind == NONCONST);

  int get hashCode {
    int hash = kind * 31 + constant.hashCode * 59 + type.hashCode * 67;
    return hash & 0x3fffffff;
  }

  bool operator ==(_AbstractValue that) {
    return that.kind == this.kind &&
           that.constant == this.constant &&
           that.type == this.type;
  }

  String toString() {
    switch (kind) {
      case NOTHING: return "Nothing";
      case CONSTANT: return "Constant: $constant: $type";
      case NONCONST: return "Non-constant: $type";
      default: assert(false);
    }
    return null;
  }

  /// Compute the join of two values in the lattice.
  _AbstractValue join(_AbstractValue that, TypeSystem typeSystem) {
    assert(that != null);

    if (isNothing) {
      return that;
    } else if (that.isNothing) {
      return this;
    } else if (isConstant && that.isConstant && constant == that.constant) {
      return this;
    } else {
      return new _AbstractValue.nonConstant(
          typeSystem.join(this.type, that.type));
    }
  }

  /// True if all members of this value are booleans.
  bool isDefinitelyBool(TypeSystem<T> typeSystem) {
    if (kind == NOTHING) return true;
    return typeSystem.isDefinitelyBool(type);
  }
}

class ConstantExpressionCreator
    implements ConstantValueVisitor<ConstantExpression, dynamic> {

  const ConstantExpressionCreator();

  ConstantExpression convert(ConstantValue value) => value.accept(this, null);

  @override
  ConstantExpression visitBool(BoolConstantValue constant, _) {
    return new BoolConstantExpression(constant.primitiveValue, constant);
  }

  @override
  ConstantExpression visitConstructed(ConstructedConstantValue constant, arg) {
    throw new UnsupportedError("ConstantExpressionCreator.visitConstructed");
  }

  @override
  ConstantExpression visitDeferred(DeferredConstantValue constant, arg) {
    throw new UnsupportedError("ConstantExpressionCreator.visitDeferred");
  }

  @override
  ConstantExpression visitDouble(DoubleConstantValue constant, arg) {
    return new DoubleConstantExpression(constant.primitiveValue, constant);
  }

  @override
  ConstantExpression visitDummy(DummyConstantValue constant, arg) {
    throw new UnsupportedError("ConstantExpressionCreator.visitDummy");
  }

  @override
  ConstantExpression visitFunction(FunctionConstantValue constant, arg) {
    throw new UnsupportedError("ConstantExpressionCreator.visitFunction");
  }

  @override
  ConstantExpression visitInt(IntConstantValue constant, arg) {
    return new IntConstantExpression(constant.primitiveValue, constant);
  }

  @override
  ConstantExpression visitInterceptor(InterceptorConstantValue constant, arg) {
    throw new UnsupportedError("ConstantExpressionCreator.visitInterceptor");
  }

  @override
  ConstantExpression visitList(ListConstantValue constant, arg) {
    throw new UnsupportedError("ConstantExpressionCreator.visitList");
  }

  @override
  ConstantExpression visitMap(MapConstantValue constant, arg) {
    throw new UnsupportedError("ConstantExpressionCreator.visitMap");
  }

  @override
  ConstantExpression visitNull(NullConstantValue constant, arg) {
    return new NullConstantExpression(constant);
  }

  @override
  ConstantExpression visitString(StringConstantValue constant, arg) {
    return new StringConstantExpression(
        constant.primitiveValue.slowToString(), constant);
  }

  @override
  ConstantExpression visitType(TypeConstantValue constant, arg) {
    throw new UnsupportedError("ConstantExpressionCreator.visitType");
  }
}