#!/usr/bin/env python3
"""把 MediaPipe selfie_multiclass_256x256（Apache 2.0）轉成 RFCore 使用的 Core ML 模型。

需求：torch、coremltools、tflite、numpy。模型：
https://storage.googleapis.com/mediapipe-models/image_segmenter/selfie_multiclass_256x256/float32/latest/selfie_multiclass_256x256.tflite
用法：python convert-selfie-multiclass.py selfie_multiclass_256x256.tflite out.mlpackage
之後：xcrun coremlcompiler compile out.mlpackage Sources/RFCore/Resources/ 並把輸出改名為 SelfieMulticlass.mlmodelc
輸入 input [1,256,256,3]（sRGB，正規化到 −1…1），輸出 output [1,256,256,6] 類別機率：
背景、頭髮、身體皮膚、臉部皮膚、衣服、其他。

做法：以 PyTorch 逐一重播 TFLite 圖中的運算（只有 11 種），追蹤後交給 coremltools。
"""
import sys
import numpy as np
import torch
import torch.nn.functional as F
import tflite
import coremltools as ct

OPS = {v: k for k, v in tflite.BuiltinOperator.__dict__.items() if not k.startswith("_")}


def activation(x, code):
    if code == tflite.ActivationFunctionType.RELU:
        return F.relu(x)
    if code == tflite.ActivationFunctionType.RELU6:
        return torch.clamp(x, 0, 6)
    if code == tflite.ActivationFunctionType.NONE:
        return x
    raise NotImplementedError(f"activation {code}")


def same_pad(x, h, w, kh, kw, sh, sw):
    """TFLite SAME padding（NCHW）；h、w 取自圖中的靜態形狀，追蹤後才是常數。"""
    ph = max((-(-h // sh) - 1) * sh + kh - h, 0)
    pw = max((-(-w // sw) - 1) * sw + kw - w, 0)
    return F.pad(x, (pw // 2, pw - pw // 2, ph // 2, ph - ph // 2))


class Replay(torch.nn.Module):
    def __init__(self, path):
        super().__init__()
        buf = open(path, "rb").read()
        self.model = tflite.Model.GetRootAsModel(buf, 0)
        self.graph = self.model.Subgraphs(0)
        self.consts = {}
        for i in range(self.graph.TensorsLength()):
            t = self.graph.Tensors(i)
            data = self.model.Buffers(t.Buffer()).DataAsNumpy()
            if isinstance(data, np.ndarray) and data.size:
                dtype = {tflite.TensorType.FLOAT32: np.float32, tflite.TensorType.INT32: np.int32}[t.Type()]
                self.consts[i] = np.frombuffer(data.tobytes(), dtype=dtype).reshape(t.ShapeAsNumpy())
        self.weights = torch.nn.ParameterDict({
            str(k): torch.nn.Parameter(torch.from_numpy(v.copy()), requires_grad=False)
            for k, v in self.consts.items() if v.dtype == np.float32})

    def const(self, i):
        return self.weights[str(i)] if str(i) in self.weights else self.consts[i]

    def forward(self, x):
        g = self.graph
        values = {g.Inputs(0): x}
        get = lambda i: values[i] if i in values else self.const(i)
        for n in range(g.OperatorsLength()):
            op = g.Operators(n)
            name = OPS[self.model.OperatorCodes(op.OpcodeIndex()).BuiltinCode()]
            ins = [op.Inputs(i) for i in range(op.InputsLength())]
            opt = op.BuiltinOptions()
            if name in ("CONV_2D", "DEPTHWISE_CONV_2D"):
                o = (tflite.Conv2DOptions if name == "CONV_2D" else tflite.DepthwiseConv2DOptions)()
                o.Init(opt.Bytes, opt.Pos)
                a = get(ins[0]).permute(0, 3, 1, 2)
                w = get(ins[1])
                b = get(ins[2]) if len(ins) > 2 and ins[2] >= 0 else None
                if name == "CONV_2D":
                    w = w.permute(0, 3, 1, 2)  # OHWI → OIHW
                    groups = 1
                else:
                    w = w.permute(3, 0, 1, 2)  # 1HWC → C1HW
                    groups = a.shape[1]
                if o.Padding() == tflite.Padding.SAME:
                    _, h, wd, _ = [int(v) for v in g.Tensors(ins[0]).ShapeAsNumpy()]
                    _, kh, kw, _ = self.consts[ins[1]].shape
                    a = same_pad(a, h, wd, kh, kw, o.StrideH(), o.StrideW())
                y = F.conv2d(a, w, b, stride=(o.StrideH(), o.StrideW()), groups=groups,
                             dilation=(o.DilationHFactor(), o.DilationWFactor()))
                y = activation(y, o.FusedActivationFunction()).permute(0, 2, 3, 1)
            elif name in ("ADD", "MUL"):
                o = (tflite.AddOptions if name == "ADD" else tflite.MulOptions)()
                o.Init(opt.Bytes, opt.Pos)
                p, q = get(ins[0]), get(ins[1])
                y = activation(p + q if name == "ADD" else p * q, o.FusedActivationFunction())
            elif name == "RESHAPE":
                shape = [int(s) for s in (self.consts[ins[1]] if len(ins) > 1 else g.Tensors(op.Outputs(0)).ShapeAsNumpy())]
                y = get(ins[0]).reshape(shape)
            elif name == "TRANSPOSE":
                y = get(ins[0]).permute(*[int(p) for p in self.consts[ins[1]]])
            elif name == "SOFTMAX":
                y = torch.softmax(get(ins[0]), dim=-1)
            elif name == "SUM":
                o = tflite.ReducerOptions()
                o.Init(opt.Bytes, opt.Pos)
                axes = [int(a) for a in np.atleast_1d(self.consts[ins[1]])]
                y = get(ins[0]).sum(dim=axes, keepdim=bool(o.KeepDims()))
            elif name in ("RESIZE_BILINEAR", "RESIZE_NEAREST_NEIGHBOR"):
                size = [int(s) for s in self.consts[ins[1]]]
                a = get(ins[0]).permute(0, 3, 1, 2)
                if name == "RESIZE_BILINEAR":
                    o = tflite.ResizeBilinearOptions()
                    o.Init(opt.Bytes, opt.Pos)
                    y = F.interpolate(a, size=size, mode="bilinear", align_corners=bool(o.AlignCorners()))
                else:
                    y = F.interpolate(a, size=size, mode="nearest")
                y = y.permute(0, 2, 3, 1)
            elif name == "TRANSPOSE_CONV":
                o = tflite.TransposeConvOptions()
                o.Init(opt.Bytes, opt.Pos)
                out_shape = [int(s) for s in self.consts[ins[0]]]
                w = get(ins[1]).permute(3, 0, 1, 2)  # OHWI → IOHW（transpose conv 的 in 為 TFLite 的 I）
                a = get(ins[2]).permute(0, 3, 1, 2)
                s = (o.StrideH(), o.StrideW())
                y = F.conv_transpose2d(a, w, None, stride=s)
                # SAME：裁掉多出的邊，使輸出等於 out_shape。
                _, ih, iw, _ = [int(v) for v in g.Tensors(ins[2]).ShapeAsNumpy()]
                _, kh, kw, _ = self.consts[ins[1]].shape
                dh = (ih - 1) * s[0] + kh - out_shape[1]
                dw = (iw - 1) * s[1] + kw - out_shape[2]
                y = y[:, :, dh // 2: dh // 2 + out_shape[1], dw // 2: dw // 2 + out_shape[2]]
                if len(ins) > 3 and ins[3] >= 0:
                    y = y + get(ins[3]).reshape(1, -1, 1, 1)
                y = y.permute(0, 2, 3, 1)
            else:
                raise NotImplementedError(name)
            values[op.Outputs(0)] = y
        return values[g.Outputs(0)]


def main(source, target):
    net = Replay(source).eval()
    sample = torch.rand(1, 256, 256, 3)
    with torch.no_grad():
        traced = torch.jit.trace(net, sample)
    model = ct.convert(traced, inputs=[ct.TensorType(name="input", shape=sample.shape)],
                       outputs=[ct.TensorType(name="output")], minimum_deployment_target=ct.target.macOS14,
                       compute_precision=ct.precision.FLOAT16)
    model.author = "Google MediaPipe (Apache 2.0), converted for RenderFilm"
    model.save(target)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
