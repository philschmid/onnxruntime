// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once

#include "onnx/defs/schema.h"
#include "xnnpack_onnx_schema.h"

namespace onnxruntime {
	constexpr const char* kXNNPackDomain = "com.microsoft.xnnpack";
}

#define ONNX_XNNPACK_OPERATOR_SET_SCHEMA(name, ver, impl) \
  ONNX_OPERATOR_SET_SCHEMA_EX(name, XnnPack, ::onnxruntime::kXNNPackDomain, ver, true, impl)



