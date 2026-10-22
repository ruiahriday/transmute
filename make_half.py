# Stores the float weights as float16 and casts them back to float32 at load time, so the file is
# half the size but the network still runs in float32 (ONNX Runtime folds the casts away).
import sys, onnx, numpy as np
from onnx import numpy_helper, helper, TensorProto
src, dst = sys.argv[1], sys.argv[2]
m = onnx.load(src)
g = m.graph
print("inputs", [(i.name, [d.dim_value or d.dim_param for d in i.type.tensor_type.shape.dim]) for i in g.input])
print("outputs", [(o.name, [d.dim_value or d.dim_param for d in o.type.tensor_type.shape.dim]) for o in g.output])
new_inits, casts = [], []
for init in g.initializer:
    if init.data_type == TensorProto.FLOAT and np.prod(init.dims) >= 16:
        arr = numpy_helper.to_array(init)
        half = numpy_helper.from_array(arr.astype(np.float16), init.name + "__f16")
        new_inits.append(half)
        casts.append(helper.make_node("Cast", [half.name], [init.name], to=TensorProto.FLOAT, name=init.name + "__cast"))
    else:
        new_inits.append(init)
del g.initializer[:]
g.initializer.extend(new_inits)
nodes = list(g.node)
del g.node[:]
g.node.extend(casts + nodes)
# initializers that were also listed as graph inputs (old exporters) must not stay inputs
names = {c.output[0] for c in casts}
keep = [i for i in g.input if i.name not in names]
del g.input[:]; g.input.extend(keep)
m.producer_name = "spinform-half"
onnx.save(m, dst)
onnx.checker.check_model(dst)
print("ok")
# keep only the main mask output; the side outputs are for training
m = onnx.load(dst)
outs = [o for o in m.graph.output if o.name == "output_image"]
del m.graph.output[:]; m.graph.output.extend(outs)
import onnx.utils
onnx.save(m, dst)
e = onnx.utils.Extractor(onnx.load(dst))
pruned = e.extract_model(["input_image"], ["output_image"])
pruned.producer_name = "spinform-half"
onnx.save(pruned, dst)
onnx.checker.check_model(dst)
print("pruned ok")
