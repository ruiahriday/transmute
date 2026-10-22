# Spinform background model

`isnet-general-use.onnx` is the IS-Net "general use" segmentation network by Xuebin Qin et al.
(https://github.com/xuebinqin/DIS, Apache License 2.0, see LICENSE-IS-Net.txt), from the ONNX export
published at https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx
(SHA-256 60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a).

Changed for Spinform: the weights are stored as float16 and cast back to float32 when the model
loads (half the download, same results within 0.002), and the training-only side outputs are removed.
The Windows build (.github/workflows/build-windows.yml on branch `windows`) downloads this file and
checks its SHA-256.
