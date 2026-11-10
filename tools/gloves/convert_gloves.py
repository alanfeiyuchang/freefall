# 把苹果示例「Animating hand models in visionOS」里的两只手套（USDZ）转成游戏用的格式，顺便换成跳伞配色。
# 用 Blender 自带的 Python（有 pxr 和 numpy）跑，不开窗口：
#
#   /Applications/Blender.app/Contents/MacOS/Blender -b --python tools/gloves/convert_gloves.py -- \
#       <AnimatingHandModels/models 目录> Freefall/Resources/Gloves
#
# 输出（和 Shared/Glove.swift 的读法对应）：
#   Glove{Left,Right}.mesh       网格：头 + 27 个关节的绑定位置 + 顶点（40 字节）+ 三角形索引
#   Glove{Left,Right}_albedo.png 反照率（sRGB）：白色布面压成炭灰，鲜艳的紫、绿点缀换成橙色，其余去色，黑色胶面不动
#   Glove_normal.png             切线空间法线（两只共用）
#   Glove_material.png           R 粗糙度、G 环境光遮蔽、B 高光强度（sRGB 编码；两只共用）
#
# 原模型的单位是厘米（骨架上有 0.01 的缩放），关节顺序和 ARKit 手部骨骼一致（27 个）。
# 苹果示例代码的许可（MIT 式）见 tools/gloves/LICENSE-Apple-sample.txt。
import os, sys, struct, zipfile, tempfile
import numpy as np
from pxr import Usd, UsdSkel, UsdGeom
import bpy

argv = sys.argv[sys.argv.index('--') + 1:]
src_dir, out_dir = argv[0], argv[1]
os.makedirs(out_dir, exist_ok=True)
ALBEDO_SIZE, NORMAL_SIZE, MATERIAL_SIZE = 2048, 2048, 1024
# 减面比例：原模型每只 12.5 万个三角形，两只在头显上要多花约 5 ms；减到三成，细节（绗缝、胶条）靠法线贴图
DECIMATE_RATIO = 0.3

def decimate(P, counts, fvi, corner_uv, ji, jw, ratio):
    """用 Blender 的折叠减面：UV 和蒙皮权重（顶点组）跟着插值。返回三角形的每个角：(点序号, uv, 法线) 和新的点、权重"""
    faces, start = [], 0
    for c in counts:
        faces.append(fvi[start:start + c].tolist())
        start += c
    me = bpy.data.meshes.new('glove')
    me.from_pydata(P.tolist(), [], faces)
    me.shade_smooth()
    uvl = me.uv_layers.new(name='uv')
    uvl.data.foreach_set('uv', corner_uv.astype(np.float32).reshape(-1))
    obj = bpy.data.objects.new('glove', me)
    bpy.context.scene.collection.objects.link(obj)
    groups = [obj.vertex_groups.new(name=str(j)) for j in range(27)]
    for v in range(len(P)):
        for k in range(ji.shape[1]):
            if jw[v, k] > 0:
                groups[int(ji[v, k])].add([v], float(jw[v, k]), 'ADD')
    mod = obj.modifiers.new('decimate', 'DECIMATE')
    mod.decimate_type = 'COLLAPSE'
    mod.ratio = ratio
    mod.use_collapse_triangulate = True
    em = obj.evaluated_get(bpy.context.evaluated_depsgraph_get()).to_mesh()
    em.calc_loop_triangles()
    nv = len(em.vertices)
    pos = np.empty(nv * 3, np.float32); em.vertices.foreach_get('co', pos); pos = pos.reshape(nv, 3)
    nl = len(em.loops)
    uv = np.empty(nl * 2, np.float32); em.uv_layers[0].data.foreach_get('uv', uv); uv = uv.reshape(nl, 2)
    cn = np.array([n.vector[:] for n in em.corner_normals], np.float32)
    nt = len(em.loop_triangles)
    tri_loops = np.empty(nt * 3, np.int64); em.loop_triangles.foreach_get('loops', tri_loops)
    loop_vert = np.empty(nl, np.int64); em.loops.foreach_get('vertex_index', loop_vert)
    w_out = np.zeros((nv, 3)); j_out = np.zeros((nv, 3), np.int64)
    for v in em.vertices:
        g = sorted(((x.weight, x.group) for x in v.groups), reverse=True)[:3]
        for k, (wt, gi) in enumerate(g):
            w_out[v.index, k], j_out[v.index, k] = wt, int(obj.vertex_groups[gi].name)
    corners = tri_loops
    return pos, loop_vert[corners], uv[corners], cn[corners], j_out, w_out


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)

def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)

def ramp(x, lo, hi):
    return np.clip((x - lo) / (hi - lo), 0.0, 1.0)

def load_pixels(path):
    img = bpy.data.images.load(path)
    img.colorspace_settings.name = 'Non-Color'      # 读原始数值，不做色彩转换
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    return px.reshape(h, w, 4), w, h

def save_pixels(rgb, w, h, path, size):
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=False)
    img.colorspace_settings.name = 'Non-Color'
    rgba = np.concatenate([rgb, np.ones((h, w, 1), np.float32)], axis=2)
    img.pixels.foreach_set(rgba.reshape(-1).astype(np.float32))
    if size != w:
        img.scale(size, size)
    img.filepath_raw = path
    img.file_format = 'PNG'
    img.save()
    bpy.data.images.remove(img)
    print('  写出', path, os.path.getsize(path) // 1024, 'KB')

shared_done = False
for side in ['Left', 'Right']:
    usdz = os.path.join(src_dir, f'{side}Glove.usdz')
    stage = Usd.Stage.Open(usdz)
    skel = next(UsdSkel.Skeleton(p) for p in stage.Traverse() if p.IsA(UsdSkel.Skeleton))
    mesh_prim = next(p for p in stage.Traverse() if p.IsA(UsdGeom.Mesh))
    mesh = UsdGeom.Mesh(mesh_prim)
    binding = UsdSkel.BindingAPI(mesh_prim)

    joints = [str(j) for j in skel.GetJointsAttr().Get()]
    assert len(joints) == 27, len(joints)
    bind = [np.array(m) for m in skel.GetBindTransformsAttr().Get()]
    bind_pos = np.array([b[3, :3] for b in bind]) * 0.01            # 行向量约定：平移在第 4 行

    mesh_joints = binding.GetJointsAttr().Get()
    remap = np.array([joints.index(str(j)) for j in mesh_joints]) if mesh_joints else np.arange(27)
    ji_pv, jw_pv = binding.GetJointIndicesPrimvar(), binding.GetJointWeightsPrimvar()
    es = ji_pv.GetElementSize()
    ji = remap[np.array(ji_pv.Get()).reshape(-1, es)]
    jw = np.array(jw_pv.Get(), dtype=np.float64).reshape(-1, es)

    gb = np.array(binding.GetGeomBindTransformAttr().Get())
    pts = np.array(mesh.GetPointsAttr().Get(), dtype=np.float64)
    P = (np.c_[pts, np.ones(len(pts))] @ gb)[:, :3] * 0.01

    counts = np.array(mesh.GetFaceVertexCountsAttr().Get())
    fvi = np.array(mesh.GetFaceVertexIndicesAttr().Get())
    corner_face = np.repeat(np.arange(len(counts)), counts)

    # 法线：模型自带的（按插值方式取到每个角上），没有就按面积加权算顶点法线
    normals = mesh.GetNormalsAttr().Get()
    interp = mesh.GetNormalsInterpolation()
    if normals is not None and len(normals) > 0:
        N = np.array(normals, dtype=np.float64) @ gb[:3, :3]
        if interp == 'faceVarying':
            corner_n = N
        elif interp in ('vertex', 'varying'):
            corner_n = N[fvi]
        else:
            corner_n = N[corner_face]
    else:
        acc = np.zeros_like(P)
        start = 0
        for c in counts:
            idx = fvi[start:start + c]
            n = np.cross(P[idx[1]] - P[idx[0]], P[idx[2]] - P[idx[0]])
            acc[idx] += n
            start += c
        corner_n = acc[fvi]
    corner_n /= np.linalg.norm(corner_n, axis=1, keepdims=True) + 1e-12
    print(side, '法线', interp, '点', len(P), '面', len(counts))

    st = UsdGeom.PrimvarsAPI(mesh_prim).GetPrimvar('st')
    stv = np.array(st.Get(), dtype=np.float64)
    st_idx = st.GetIndices()
    if st_idx is not None and len(st_idx) > 0:
        stv = stv[np.array(st_idx)]
    st_interp = st.GetInterpolation()
    corner_uv = stv if st_interp == 'faceVarying' else stv[fvi]
    corner_uv = np.c_[corner_uv[:, 0], 1.0 - corner_uv[:, 1]]       # Metal 的纹理原点在左上

    if DECIMATE_RATIO < 1:
        P, corner_point, corner_uv, corner_n, ji, jw = decimate(P, counts, fvi, corner_uv, ji, jw, DECIMATE_RATIO)
        fvi = corner_point
        counts = np.full(len(fvi) // 3, 3)
        corner_n = corner_n / (np.linalg.norm(corner_n, axis=1, keepdims=True) + 1e-12)
        print(side, '减面后', len(P), '点', len(counts), '三角形')

    # 拆顶点：同一个点在 UV 接缝两边要变成两个顶点（法线也一样）
    key = np.c_[fvi, np.round(corner_uv * 65536).astype(np.int64), np.round(corner_n * 4096).astype(np.int64)]
    uniq, first, inverse = np.unique(key, axis=0, return_index=True, return_inverse=True)
    inverse = inverse.reshape(-1)
    vp = fvi[first]
    positions = P[vp].astype(np.float32)
    vnormals = corner_n[first].astype(np.float32)
    uvs = corner_uv[first].astype(np.float32)
    w = jw[vp]
    w = w / np.maximum(w.sum(axis=1, keepdims=True), 1e-9)
    j = ji[vp]
    # 权重量化成 0…255，和凑成 255
    wq = np.floor(w * 255 + 0.5).astype(np.int64)
    wq[:, 0] += 255 - wq.sum(axis=1)
    pad = 4 - es
    j4 = np.c_[j, np.zeros((len(j), pad), np.int64)].astype(np.uint8)
    w4 = np.c_[wq, np.zeros((len(wq), pad), np.int64)].clip(0, 255).astype(np.uint8)

    # 三角化（扇形），索引指向拆过的顶点
    tris = []
    start = 0
    for c in counts:
        for k in range(1, c - 1):
            tris.append((inverse[start], inverse[start + k], inverse[start + k + 1]))
        start += c
    tris = np.array(tris, dtype=np.uint32)
    print(side, '顶点', len(positions), '三角形', len(tris))

    out_mesh = os.path.join(out_dir, f'Glove{side}.mesh')
    with open(out_mesh, 'wb') as f:
        f.write(b'GLV1')
        f.write(struct.pack('<III', len(positions), tris.size, 27))
        f.write(bind_pos.astype('<f4').tobytes())
        vbuf = np.zeros(len(positions), dtype=[('p', '<f4', 3), ('u', '<f4'), ('n', '<f4', 3), ('v', '<f4'),
                                                ('j', 'u1', 4), ('w', 'u1', 4)])
        vbuf['p'], vbuf['u'], vbuf['n'], vbuf['v'] = positions, uvs[:, 0], vnormals, uvs[:, 1]
        vbuf['j'], vbuf['w'] = j4, w4
        assert vbuf.dtype.itemsize == 40
        f.write(vbuf.tobytes())
        f.write(tris.astype('<u4').tobytes())
    print('  写出', out_mesh, os.path.getsize(out_mesh) // 1024, 'KB',
          '关节 0→9（腕→食指尖）', np.linalg.norm(bind_pos[9] - bind_pos[0]).round(3), 'm')

    # 贴图：从 usdz 里取出来
    tmp = tempfile.mkdtemp()
    with zipfile.ZipFile(usdz) as z:
        z.extractall(tmp)
    # usdz 里还套着一层 usdz（贴图在里面那层），一路解开
    nested = True
    while nested:
        nested = False
        for root, _, files in os.walk(tmp):
            for fn in files:
                if fn.endswith('.usdz'):
                    inner = os.path.join(root, fn)
                    with zipfile.ZipFile(inner) as z:
                        z.extractall(inner + '_x')
                    os.remove(inner)
                    nested = True
    def find(name):
        for root, _, files in os.walk(tmp):
            for fn in files:
                if fn == name:
                    return os.path.join(root, fn)
        raise FileNotFoundError(name)

    albedo_name = next(fn for root, _, files in os.walk(tmp) for fn in files if fn.lower().endswith('_albedo.png'))
    print('  反照率贴图', albedo_name)
    px, w_, h_ = load_pixels(find(albedo_name))
    lin = srgb_to_linear(px[:, :, :3])
    mx, mn = lin.max(axis=2), lin.min(axis=2)
    sat = np.where(mx > 1e-6, (mx - mn) / np.maximum(mx, 1e-6), 0.0)
    mask = (ramp(sat, 0.25, 0.4) * ramp(mx, 0.3, 0.5))[:, :, None]
    # 不是橙色点缀的地方一律去色再压暗（原来手心那块淡紫色也变成炭灰）
    lum = (lin @ np.array([0.2126, 0.7152, 0.0722], np.float32))[:, :, None]
    dark = lum * np.array([0.075, 0.075, 0.085], np.float32)
    orange = np.array([0.62, 0.17, 0.018], np.float32)      # 偏暗的橙（太亮在高空的太阳下发黄、像金属）
    out = dark * (1 - mask) + orange * mask
    save_pixels(linear_to_srgb(out).astype(np.float32), w_, h_, os.path.join(out_dir, f'Glove{side}_albedo.png'),
                ALBEDO_SIZE)

    if not shared_done:
        nrm, w_, h_ = load_pixels(find('Glove3_Normal.png'))
        save_pixels(nrm[:, :, :3], w_, h_, os.path.join(out_dir, 'Glove_normal.png'), NORMAL_SIZE)
        rough, w_, h_ = load_pixels(find('Glove3_Roughness.png'))
        ao, _, _ = load_pixels(find('Glove3_AO.png'))
        gloss, _, _ = load_pixels(find('Glove3_Gloss.png'))
        print('  粗糙度均值', rough[:, :, 0].mean().round(3), 'AO 均值', ao[:, :, 0].mean().round(3),
              '高光（sRGB）均值', gloss[:, :, 0].mean().round(3))
        mat = np.stack([rough[:, :, 0], ao[:, :, 0], gloss[:, :, 0]], axis=2)
        save_pixels(mat, w_, h_, os.path.join(out_dir, 'Glove_material.png'), MATERIAL_SIZE)
        shared_done = True
