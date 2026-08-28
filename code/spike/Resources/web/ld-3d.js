/* 皮肤共用的 3D 层（Three.js 版）：全息着色 + 程序化模型 + FBX / GLB（含 Draco）加载 + 骨骼动画由状态驱动。
   依赖 three.bundle.js（vendor-three.sh 打出来的 IIFE，全局 LD_THREE：THREE / GLTFLoader / DRACOLoader / FBXLoader）。
   为什么从自写渲染器换成 Three：用户要的是 Mixamo 那类带骨骼动画的角色（FBX），自写解析器补蒙皮 + FBX 不划算（决策 008）。
   模型来源：内置程序化模型（__ld3d.builtin[name]），或用户放在 ~/.config/live-desktop/models/ 的 .glb / .gltf / .fbx
   （宿主经 ld-model:// scheme 供文件与 Draco 解码器）。
   全息风格：单色、菲涅尔边缘光、扫描线、线框——加载进来的材质贴图一律忽略，只用几何与骨骼。 */
(function () {
  const LIB = window.LD_THREE;
  if (!LIB || !LIB.THREE) { window.__ld3d = { available: false, reason: 'three.bundle.js 未加载' }; return; }
  const { THREE, GLTFLoader, DRACOLoader, FBXLoader } = LIB;
  const TAU = Math.PI * 2;

  /* ── 全息材质：ShaderMaterial，顶点阶段套 Three 的蒙皮 chunk，所以 SkinnedMesh 直接能用 ─────── */
  const VERT = `
    #include <common>
    #include <skinning_pars_vertex>
    uniform vec2 uNdc;
    varying vec3 vN; varying vec3 vV; varying float vY;
    void main() {
      #include <beginnormal_vertex>
      #include <skinbase_vertex>
      #include <skinnormal_vertex>
      #include <begin_vertex>
      #include <skinning_vertex>
      vec4 wp = modelMatrix * vec4(transformed, 1.0);
      vec4 mv = modelViewMatrix * vec4(transformed, 1.0);
      vN = normalize(normalMatrix * objectNormal);
      vV = normalize(-mv.xyz);
      vY = wp.y;
      gl_Position = projectionMatrix * mv;
      gl_Position.xy += uNdc * gl_Position.w;
    }`;
  const FRAG = `
    uniform vec3 uColor; uniform float uAlpha, uTime, uScanY, uLine;
    varying vec3 vN; varying vec3 vV; varying float vY;
    void main() {
      float ping = exp(-abs(vY - uScanY) * 30.0);                          // 扫描面经过处发亮
      if (uLine > 0.5) { gl_FragColor = vec4(uColor * (1.0 + ping), uAlpha * (1.0 + ping * 0.8)); return; }
      float fres = pow(1.0 - abs(dot(normalize(vN), normalize(vV))), 2.2);   // 菲涅尔：边缘亮、正面透
      float scan = 0.80 + 0.20 * sin(gl_FragCoord.y * 0.8 - uTime * 7.0);   // 全息扫描线
      float a = (0.08 + 0.50 * fres) * scan + ping * 0.9;
      gl_FragColor = vec4(uColor * (1.0 + ping * 0.8), a * uAlpha);
    }`;
  function holoMaterial(shared, color, line, wireframe) {
    return new THREE.ShaderMaterial({
      vertexShader: VERT, fragmentShader: FRAG,
      uniforms: Object.assign({ uColor: { value: color }, uLine: { value: line ? 1 : 0 } }, shared),
      transparent: true, depthWrite: false, depthTest: false, wireframe: !!wireframe, side: THREE.FrontSide,
      blending: THREE.CustomBlending, blendEquation: THREE.AddEquation,
      blendSrc: THREE.SrcAlphaFactor, blendDst: THREE.OneFactor, blendSrcAlpha: THREE.OneFactor, blendDstAlpha: THREE.OneMinusSrcAlphaFactor,
    });
  }

  /* ── 程序化内置模型：返回 Group，userData.spins = [{ obj, axis, speed }]（部件绕自身枢轴独立转） ─────── */
  const mesh = (geo, x, y, z) => { const m = new THREE.Mesh(geo); if (x !== undefined) m.position.set(x, y, z); return m; };
  const group = (...children) => { const g = new THREE.Group(); children.forEach(c => g.add(c)); return g; };
  const spin = (root, obj, axis, speed) => { (root.userData.spins ||= []).push({ obj, axis: new THREE.Vector3(...axis).normalize(), speed }); return obj; };
  const flatTorus = (R, r, seg) => { const m = mesh(new THREE.TorusGeometry(R, r, 12, seg || 64)); m.rotation.x = Math.PI / 2; return m; };
  const builtin = {
    // 3D 版反应堆：三个不同轴的环 + 核心
    reactor() {
      const root = new THREE.Group();
      const ring1 = group(flatTorus(1.0, 0.05));
      for (let i = 0; i < 8; i++) { const b = mesh(new THREE.BoxGeometry(0.06, 0.18, 0.06)); b.position.set(Math.cos(i / 8 * TAU), 0, Math.sin(i / 8 * TAU)); ring1.add(b); }
      const ring2 = group(mesh(new THREE.TorusGeometry(0.82, 0.04, 12, 64)));
      const ring3 = group(mesh(new THREE.TorusGeometry(0.64, 0.035, 12, 64))); ring3.rotation.y = Math.PI / 2;
      const inner = mesh(new THREE.TorusGeometry(0.42, 0.015, 8, 48)); inner.rotation.x = 0.6 + Math.PI / 2;
      const core = group(mesh(new THREE.SphereGeometry(0.3, 24, 18)), inner);
      root.add(spin(root, ring1, [0, 1, 0], 0.6), spin(root, ring2, [1, 0, 0], 1.1), spin(root, ring3, [0, 0, 1], -0.9), spin(root, core, [0, 1, 0], 0.3));
      return root;
    },
    // 空间站：轮环 + 四辐条 + 轮毂 + 太阳板
    station() {
      const root = new THREE.Group();
      const wheel = group(flatTorus(1.0, 0.11));
      for (let i = 0; i < 4; i++) { const s = mesh(new THREE.BoxGeometry(0.9, 0.05, 0.05)); s.position.set(Math.cos(i / 4 * TAU) * 0.55, 0, Math.sin(i / 4 * TAU) * 0.55); s.rotation.y = -i / 4 * TAU; wheel.add(s); }
      const hub = group(mesh(new THREE.CylinderGeometry(0.22, 0.22, 0.9, 24)), mesh(new THREE.CylinderGeometry(0.1, 0.1, 1.6, 12)),
                        mesh(new THREE.BoxGeometry(0.5, 0.02, 1.2), 0, 0.85, 0), mesh(new THREE.BoxGeometry(0.5, 0.02, 1.2), 0, -0.85, 0));
      root.add(spin(root, wheel, [0, 1, 0], 0.5), spin(root, hub, [0, 1, 0], -0.25));
      return root;
    },
    // 卫星：机身 + 天线 + 两翼太阳板（缓慢对日转动）+ 抛物面天线
    satellite() {
      const root = new THREE.Group();
      const body = group(mesh(new THREE.BoxGeometry(0.5, 0.5, 0.7)), mesh(new THREE.CylinderGeometry(0.03, 0.03, 0.6, 8), 0, 0.55, 0), mesh(new THREE.SphereGeometry(0.05, 10, 8), 0, 0.85, 0));
      const panels = new THREE.Group();
      for (const x of [0.95, -0.95]) { panels.add(mesh(new THREE.BoxGeometry(1.2, 0.02, 0.5), x, 0, 0)); const arm = mesh(new THREE.CylinderGeometry(0.025, 0.025, 0.6, 8), x / 2, 0, 0); arm.rotation.z = Math.PI / 2; panels.add(arm); }
      const dish = mesh(new THREE.LatheGeometry([new THREE.Vector2(0, 0), new THREE.Vector2(0.15, 0.02), new THREE.Vector2(0.3, 0.08), new THREE.Vector2(0.42, 0.18)], 32), 0, 0, 0.45);
      dish.rotation.x = Math.PI / 2;
      root.add(body, spin(root, panels, [1, 0, 0], 0.25), dish);
      return root;
    },
    // 无人机：机身 + 四臂 + 四个高速旋翼
    drone() {
      const root = new THREE.Group();
      root.add(mesh(new THREE.BoxGeometry(0.45, 0.14, 0.45)), mesh(new THREE.BoxGeometry(0.2, 0.08, 0.3), 0, -0.1, 0.2));
      for (let i = 0; i < 4; i++) {
        const a = i / 4 * TAU + Math.PI / 4, x = Math.cos(a) * 0.75, z = Math.sin(a) * 0.75;
        const arm = mesh(new THREE.BoxGeometry(0.7, 0.04, 0.06), x / 2, 0, z / 2); arm.rotation.y = -Math.atan2(z, x); root.add(arm);
        root.add(mesh(new THREE.TorusGeometry(0.28, 0.015, 6, 32), x, 0.04, z).rotateX(Math.PI / 2));
        const blades = group(mesh(new THREE.BoxGeometry(0.5, 0.01, 0.05)), mesh(new THREE.BoxGeometry(0.05, 0.01, 0.5))); blades.position.set(x, 0.06, z);
        root.add(spin(root, blades, [0, 1, 0], i % 2 ? 9 : -9));
      }
      return root;
    },
    // 双螺旋：两条螺旋管 + 横档
    helix() {
      class Helix extends THREE.Curve { constructor(ph) { super(); this.ph = ph; } getPoint(u, o = new THREE.Vector3()) { const t = u * 12.5; return o.set(Math.cos(t + this.ph) * 0.5, t * 0.16 - 1.0, Math.sin(t + this.ph) * 0.5); } }
      const root = new THREE.Group(), all = new THREE.Group();
      const h0 = new Helix(0), h1 = new Helix(Math.PI);
      all.add(mesh(new THREE.TubeGeometry(h0, 96, 0.045, 8, false)), mesh(new THREE.TubeGeometry(h1, 96, 0.045, 8, false)));
      for (let t = 0.3; t < 12.5; t += 0.55) {
        const a = h0.getPoint(t / 12.5), b = h1.getPoint(t / 12.5), dir = b.clone().sub(a);
        const rung = mesh(new THREE.CylinderGeometry(0.02, 0.02, dir.length(), 6)); rung.position.copy(a).add(b).multiplyScalar(0.5);
        rung.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), dir.normalize()); all.add(rung);
      }
      root.add(spin(root, all, [0, 1, 0], 0.5));
      return root;
    },
  };

  /* 烘焙：把每个转动部件（以及根）下面的多个 Mesh 合并成一个，draw call 数降到"部件数 × 2"。
     WebKit 的 WebGL 在独立 GPU 进程里执行，每个绘制命令都要跨进程，命令数比三角形数贵得多：
     reactor 26 次 draw call 比 55k 三角、4 次 draw call 的蒙皮舞者还费 CPU（2026-08-27 实测）。只用于程序化模型；外部模型的节点可能各自带动画，不动。 */
  function bake(root) {
    root.updateMatrixWorld(true);
    const spinObjs = new Set((root.userData.spins || []).map(s => s.obj));
    const owners = new Map();
    root.traverse(o => {
      if (!o.isMesh) return;
      let p = o.parent; while (p && p !== root && !spinObjs.has(p)) p = p.parent;
      const owner = p || root; if (!owners.has(owner)) owners.set(owner, []); owners.get(owner).push(o);
    });
    for (const [owner, meshes] of owners) {
      if (meshes.length < 2) continue;
      const inv = owner.matrixWorld.clone().invert();
      const geos = meshes.map(m => m.geometry.toNonIndexed().applyMatrix4(inv.clone().multiply(m.matrixWorld)));
      let n = 0; for (const g of geos) n += g.attributes.position.count;
      const pos = new Float32Array(n * 3), nrm = new Float32Array(n * 3); let off = 0;
      for (const g of geos) { pos.set(g.attributes.position.array, off * 3); if (g.attributes.normal) nrm.set(g.attributes.normal.array, off * 3); off += g.attributes.position.count; g.dispose(); }
      const merged = new THREE.BufferGeometry();
      merged.setAttribute('position', new THREE.BufferAttribute(pos, 3)); merged.setAttribute('normal', new THREE.BufferAttribute(nrm, 3));
      for (const m of meshes) { m.parent.remove(m); m.geometry.dispose(); }
      owner.add(new THREE.Mesh(merged));
    }
    return root;
  }

  /* ── 加载：内置名 / user/<文件> / 调试用 http(s) 绝对地址；按扩展名选加载器 ─────── */
  let gltfLoader = null, fbxLoader = null;
  function loaders() {
    if (!gltfLoader) {
      gltfLoader = new GLTFLoader();
      const draco = new DRACOLoader(); draco.setDecoderPath('ld-model://lib/draco/'); gltfLoader.setDRACOLoader(draco);
      fbxLoader = new FBXLoader();
    }
    return { gltfLoader, fbxLoader };
  }
  async function loadModel(name) {
    const isUrl = /^https?:\/\//.test(name);
    if (!isUrl && !name.startsWith('user/')) { const f = builtin[name]; if (!f) throw new Error('未知模型 ' + name); return { object: bake(f()), animations: [], source: name }; }
    const url = isUrl ? name : 'ld-model://file/' + encodeURIComponent(name.slice(5));
    const ext = name.split('?')[0].split('.').pop().toLowerCase();
    const { gltfLoader, fbxLoader } = loaders();
    if (ext === 'fbx') { const obj = await fbxLoader.loadAsync(url); return { object: obj, animations: obj.animations || [], source: name }; }
    if (ext === 'glb' || ext === 'gltf') { const g = await gltfLoader.loadAsync(url); return { object: g.scene, animations: g.animations || [], source: name }; }
    throw new Error('不支持的格式 .' + ext + '（支持 glb / gltf / fbx）');
  }
  async function listModels() {
    const out = Object.keys(builtin);
    try { const r = await fetch('ld-model://list'); if (r.ok) for (const f of await r.json()) out.push('user/' + f); } catch (e) { /* 浏览器里调试没有宿主 */ }
    return out;
  }

  /* 动作片段按状态挑：多段时用名字关键词，单段就一直放；播放速度随活跃度（待机慢放、执行全速） */
  const PHASE_CLIP = {
    idle: /idle|stand|breath|wait|rest/i, waiting: /wave|hello|greet|look|idle|talk/i,
    thinking: /think|idle|look|scratch/i, running: /danc|samba|run|walk|action|jump|work|typ|fight|punch/i,
  };
  function pickClip(clips, phase) {
    if (!clips.length) return null;
    if (clips.length === 1) return clips[0];
    const re = PHASE_CLIP[phase] || PHASE_CLIP.idle;
    return clips.find(c => re.test(c.name)) || clips[0];
  }

  /* ── 渲染器 ─────────────────────────────────────────────────── */
  function Renderer(canvas) {
    let renderer;
    try { renderer = new THREE.WebGLRenderer({ canvas, alpha: true, antialias: true, premultipliedAlpha: true, powerPreference: 'low-power' }); }
    catch (e) { return null; }
    renderer.setPixelRatio(1); renderer.setClearColor(0x000000, 0);
    const scene = new THREE.Scene();
    const camera = new THREE.PerspectiveCamera(35.5, 1, 0.1, 100);
    camera.position.set(0, 1.28, 6.3); camera.lookAt(0, 0, 0);   // 略俯视；模型（边长 2）约占视口高度一半
    const root = new THREE.Group(); scene.add(root);               // 自转挂点
    const shared = { uAlpha: { value: 1 }, uTime: { value: 0 }, uScanY: { value: -99 }, uNdc: { value: new THREE.Vector2() } };
    const keyColor = new THREE.Color(), hiColor = new THREE.Color();
    const solidMat = holoMaterial(shared, keyColor, false, false);
    const lineMat = holoMaterial(shared, hiColor, true, false);
    const wireMat = holoMaterial(shared, hiColor, true, true);
    let model = null, mixer = null, clips = [], action = null, meta = { tris: 0, clips: [], clip: null, timeScale: 1, skinned: false };
    const applied = { w: -1, h: -1 };

    function dispose(obj) {
      obj.traverse(o => { if (o.geometry) o.geometry.dispose(); if (o.skeleton && o.skeleton.boneTexture) o.skeleton.boneTexture.dispose(); });
    }
    /* 套全息材质：静态网格加特征线框（EdgesGeometry），蒙皮网格用同骨架的 wireframe 副本（EdgesGeometry 不带蒙皮属性） */
    function holographize(obj) {
      const add = []; let tris = 0, skinned = false;
      obj.traverse(o => {
        if (!o.isMesh) return;
        o.material = solidMat; o.frustumCulled = false;
        const g = o.geometry, n = g.index ? g.index.count / 3 : g.attributes.position.count / 3; tris += n;
        if (o.isSkinnedMesh) { skinned = true; const w = o.clone(); w.material = wireMat; add.push([o.parent, w]); }
        else {
          const dense = n > 2500;   // 密网格只画折边（CAD 隐藏线），稀疏网格连小角度也画（程序化模型的环 / 管）
          const edges = new THREE.LineSegments(new THREE.EdgesGeometry(g, dense ? 28 : 1), lineMat);
          add.push([o, edges]);
        }
      });
      for (const [parent, child] of add) parent.add(child);
      // 线框透明度按线段总数自适应：几百条清晰、几万条只剩薄雾
      let segs = 0; obj.traverse(o => { if (o.isLineSegments) segs += o.geometry.attributes.position.count / 2; if (o.isMesh && o.material === wireMat) segs += (o.geometry.index ? o.geometry.index.count : o.geometry.attributes.position.count); });
      wireMat.uniforms.uAlpha = lineMat.uniforms.uAlpha = { value: Math.max(0.12, Math.min(0.8, 0.8 * 1200 / Math.max(1, segs))) };
      return { tris, skinned };
    }
    /* 归一化：最长边缩到 2、x/z 居中。竖直方向一套几何规则适配所有模型（用户会放自己的模型，不为某个模型单独配置）：
       高度是主导维度（≥ 最长边的 85%：站立的角色、雕像、螺旋、环）→ 脚底落在 y = -1，站在投影台上；
       否则（卫星、无人机这类扁宽物体）→ 包围盒中心对齐原点，悬浮在光锥中央。之前按"有没有骨骼"分，静态人像会被错当成物体悬空。 */
    function normalize(obj) {
      const box = new THREE.Box3().setFromObject(obj);
      if (box.isEmpty()) return { holder: obj, standing: false, size: [0, 0, 0] };
      const size = new THREE.Vector3(), center = new THREE.Vector3(); box.getSize(size); box.getCenter(center);
      const maxDim = Math.max(size.x, size.y, size.z) || 1, k = 2 / maxDim, standing = size.y >= 0.85 * maxDim;
      const holder = new THREE.Group(); holder.add(obj);
      holder.scale.setScalar(k); holder.position.set(-center.x * k, standing ? -1 - box.min.y * k : -center.y * k, -center.z * k);
      return { holder, standing, size: [size.x * k, size.y * k, size.z * k].map(v => +v.toFixed(2)) };
    }
    function setModel(loaded) {
      if (model) { root.remove(model); dispose(model); }
      if (mixer) { mixer.stopAllAction(); mixer = null; action = null; }
      model = null; clips = []; meta = { tris: 0, clips: [], clip: null, timeScale: 1, skinned: false, standing: false, size: [0, 0, 0] };
      if (!loaded) return;
      const obj = loaded.object;
      const info = holographize(obj);
      const n = normalize(obj); model = n.holder; root.add(model); meta.standing = n.standing; meta.size = n.size;
      clips = loaded.animations || [];
      meta.tris = Math.round(info.tris); meta.skinned = info.skinned; meta.clips = clips.map(c => c.name);
      if (clips.length) mixer = new THREE.AnimationMixer(obj);
      model.userData.spins = obj.userData.spins || [];
    }
    function setPhase(phase, energy) {
      if (!mixer) return;
      const clip = pickClip(clips, phase);
      if (clip && (!action || action.getClip() !== clip)) {
        const next = mixer.clipAction(clip).reset().setEffectiveWeight(1).fadeIn(0.4).play();
        if (action) action.fadeOut(0.4);
        action = next; meta.clip = clip.name;
      }
      mixer.timeScale = meta.timeScale = 0.25 + energy * 1.0;   // 待机 ~0.4x，执行工具 ~1.1x
    }
    /* o = { t, dt, partT, yaw, phase, energy, color, hi, alpha, scanY, glitch(0..1), ndc:[x,y] } */
    function render(o) {
      const W = canvas.width, H = canvas.height;
      // 尺寸 / 宽高比要用自己记的"已应用尺寸"判断：渲染器是在画布已定尺寸后创建的，renderer.getSize() 一开始就等于画布，
      // 拿它当判据会导致 camera.aspect 永远停在初始值 1，模型被按屏幕宽高比横向拉宽（2026-08-27 用户肉眼发现）
      if (applied.w !== W || applied.h !== H) { applied.w = W; applied.h = H; renderer.setSize(W, H, false); camera.aspect = W / H; camera.updateProjectionMatrix(); }
      shared.uTime.value = o.t || 0; shared.uScanY.value = o.scanY == null ? -99 : o.scanY; shared.uAlpha.value = o.alpha == null ? 1 : o.alpha;
      shared.uNdc.value.set(o.ndc ? o.ndc[0] : 0, o.ndc ? o.ndc[1] : 0);
      keyColor.setRGB(o.color[0] / 255, o.color[1] / 255, o.color[2] / 255); hiColor.setRGB(o.hi[0] / 255, o.hi[1] / 255, o.hi[2] / 255);
      root.rotation.y = o.yaw || 0;
      if (model) for (const s of model.userData.spins || []) s.obj.quaternion.setFromAxisAngle(s.axis, (o.partT || 0) * s.speed);
      if (mixer) { setPhase(o.phase || 'idle', o.energy || 0); mixer.update(Math.min(0.1, o.dt || 0.016)); }
      renderer.setScissorTest(false); root.position.x = 0;
      renderer.render(scene, camera);
      if (o.glitch > 0 && model) {   // 全息故障：两条横带整体错位（scissor 内清掉再画一遍偏移的）
        renderer.setScissorTest(true);
        for (let k = 0; k < 2; k++) {
          const y = Math.floor((Math.sin((o.t || 0) * 37 + k * 5) * 0.5 + 0.5) * H), h = Math.floor(H * (0.03 + 0.05 * k));
          renderer.setScissor(0, y, W, h); root.position.x = (k ? -1 : 1) * 0.14 * o.glitch; renderer.render(scene, camera);
        }
        renderer.setScissorTest(false); root.position.x = 0;
      }
    }
    // 世界坐标 → 像素（皮肤用它把 2D 底座画在模型脚下），ndc 与 render 传的同一个偏移
    function project(x, y, z, ndc) {
      const v = new THREE.Vector3(x, y, z).project(camera);
      const nx = v.x + (ndc ? ndc[0] : 0), ny = v.y + (ndc ? ndc[1] : 0);
      return [(nx + 1) / 2 * canvas.width, (1 - ny) / 2 * canvas.height];
    }
    return { setModel, render, project, get model() { return model; }, get meta() { return meta; }, three: { renderer, scene, camera } };
  }

  window.__ld3d = { available: true, revision: THREE.REVISION, Renderer, builtin: Object.keys(builtin), loadModel, listModels };
})();
