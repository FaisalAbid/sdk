// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#ifndef VM_CPUID_H_
#define VM_CPUID_H_

#include "vm/globals.h"
#if !defined(TARGET_OS_MACOS)
#include "vm/allocation.h"
#include "vm/cpuinfo.h"

namespace dart {

class CpuId : public AllStatic {
 public:
#if defined(HOST_ARCH_IA32) || defined(HOST_ARCH_X64)
  static void InitOnce();
  static void Cleanup();

  // Caller must free the result of field.
  static const char* field(CpuInfoIndices idx);
#else
  static void InitOnce() {}
  static void Cleanup() {}
  static const char* field(CpuInfoIndices idx) { return NULL; }
#endif

  static bool sse2() { return sse2_; }
  static bool sse41() { return sse41_; }

  // Caller must free the result of id_string and brand_string.
  static const char* id_string();
  static const char* brand_string();

 private:
  static bool sse2_;
  static bool sse41_;
  static const char* id_string_;
  static const char* brand_string_;

  static void GetCpuId(int32_t level, uint32_t info[4]);
};

}  // namespace dart

#endif  // !defined(TARGET_OS_MACOS)
#endif  // VM_CPUID_H_
