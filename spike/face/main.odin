// P2, the face — increment 1: the replay viewer, measured the fork's way.
//
// The spec's §13.12 closed the native surface as "waits until someone is
// actually asking" — this is the ask, answered with a measurement rather than
// an argument. One Odin program:
//
//   odin run spike/face -file -- <transcript.jsonl> [--png <prefix>]
//
// replays a recorded match (golden/stream-1m.jsonl) through a Vulkan
// renderer, offscreen, no window: instance, device, an 800x800 linear-tiled
// host-visible color attachment, one flat-colored quad per entity, the pixels
// read back from mapped memory. The pixels ARE the gate: per-frame FNV-1a
// digests are printed and pinned in spike/gates.sh (gate 11); --png writes a
// PPM per sampled frame for the operator's eye.
//
// The GPU renders what the transcript SAYS — the transcript is the contract,
// so the viewer can be judged byte-for-byte before any live play exists. The
// interactive SDL2 window and the live camera are the next increments; this
// one only has to be RIGHT.
package face

import "core:fmt"
import "core:encoding/json"
import "core:dynlib"
import "core:os"
import "core:strconv"
import "core:time"
import "core:strings"
import "core:math"
import "core:mem"
import sdl "vendor:sdl2"
import vk "vendor:vulkan"

W :: 800
H :: 800

// the civ colors (js/civilizations.js), by seat order
CIV_COLORS := [4][3]f32{
	{1.0, 0.843, 0.0},   // egyptian gold 0xffd700
	{0.2, 0.6, 1.0},     // greek
	{0.85, 0.2, 0.2},    // persian
	{0.9, 0.55, 0.1},    // yamato
}

entity :: struct {
	x, z:  f64,
	kind:  i32, // 0 unit, 1 building, 2..6 map node kinds
	seat:  i32,
	worker: bool, // units: a villager (smaller mark, as the reference draws its own)
	eid:    i32, // the record's id: the correspondence key between turns
}

frame :: struct {
	turn:   int,
	ents:   [1024]entity,
	n:      int,
	nodes:  [1024]entity, // the map line's resource nodes: static scenery
	nn:     int,
	fog:    [49]i32, // the state's map.exploration: 7x7 tiles, 0..100% seen
	has_fog: bool,
	res:    [4][4]i32, // per seat: food, wood, stone, gold
	pop:    [4][2]i32, // per seat: used, capacity
	turn_no: int,
	battles: [8][2]f64, // the state's ongoing battles: ring positions
	n_battles: int,
}

camera :: struct {
	zoom:    f32, // world→screen scale, 1 = the whole map fits
	cx, cz:  f32, // the world point at the screen's centre
}

// FNV-1a 64, the transcript's own diagnostic hash (game.js stateDigest)
fnv :: proc(data: []byte) -> u64 {
	h := u64(0xcbf29ce484222325)
	for b in data {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	return h
}

// ---------------------------------------------------------------- the scene

// jnum: the number the variant holds (the parser makes i64 for integers,
// f64 for everything else)
jnum :: proc(v: json.Value) -> f64 {
	switch x in v {
	case json.Integer:
		return f64(x)
	case json.Float:
		return x
	case json.Null, json.Boolean, json.String, json.Array, json.Object:
		return 0
	}
	return 0
}

// jnum2: an object field as f64 (0 when absent)
jnum2 :: proc(o: json.Object, key: string) -> f64 {
	v, has := o[key]
	if !has {
		return 0
	}
	return jnum(v)
}

// node_kind: the map line's resource types, drawn in distinct colours
node_kind :: proc(s: string) -> i32 {
	if s == "food" {
		return 1
	}
	if s == "wood" {
		return 2
	}
	if s == "stone" {
		return 3
	}
	if s == "gold" {
		return 4
	}
	return 0
}

// fog_cell: an exploration entry "C5": 42 — the tile at column C, row 5 has
// 42% of its cells seen. The grid is 7x7 tiles in label order.
fog_cell :: proc(f: ^frame, key: string, val: f64) {
	if len(key) < 2 {
		return
	}
	col := int(key[0] - 'A')
	row := int(key[1] - '1')
	if col < 0 || col > 6 || row < 0 || row > 6 {
		return
	}
	f.fog[row * 7 + col] = i32(val)
}

scene_fill :: proc(v: json.Value, f: ^frame) {
	// no resets here: the driver clears a turn's frame at its first record;
	// the four seat records then accumulate into one scene
	obj, o_ok := v.(json.Object)
	if !o_ok {
		return
	}
	tv_type, type_has := obj["type"]
	if type_has {
		if ts, ok := tv_type.(json.String); ok && ts == "map" {
			// the static scenery: the map line's resource nodes
			if rv, has := obj["resources"]; has {
				if items, a_ok := rv.(json.Array); a_ok {
					for item in items {
						io, ok := item.(json.Object)
						if !ok {
							continue
						}
						x, z := jnum2(io, "x"), jnum2(io, "z")
						nt: i32 = 0
						if ttv, has := io["t"]; has {
							if tts, ok := ttv.(json.String); ok {
								nt = node_kind(tts)
							}
						}
						if f.nn < len(f.nodes) {
							f.nodes[f.nn] = entity{x = x, z = z, kind = 2 + nt, seat = 0}
							f.nn += 1
						}
					}
				}
			}
			return
		}
	}
	tval, has := obj["turn"]
	if !has {
		return // match/map/results/timeline lines
	}
	stval, st_has := obj["state"]
	if !st_has {
		return
	}
	st, s_ok := stval.(json.Object)
	if !s_ok {
		return
	}
	seat_i := 0
	if pval, has := st["player"]; has {
		if po, ok := pval.(json.Object); ok {
			if sv, has := po["seat"]; has {
				seat_i = int(jnum(sv))
			}
		}
	}
	// the HUD row for THIS record's seat: its resources and population
	if rv, has := st["resources"]; has {
		if ro, ok := rv.(json.Object); ok {
			f.res[seat_i][0] = i32(jnum2(ro, "food"))
			f.res[seat_i][1] = i32(jnum2(ro, "wood"))
			f.res[seat_i][2] = i32(jnum2(ro, "stone"))
			f.res[seat_i][3] = i32(jnum2(ro, "gold"))
		}
	}
	if pv, has := st["population"]; has {
		if po, ok := pv.(json.Object); ok {
			f.pop[seat_i][0] = i32(jnum2(po, "used"))
			f.pop[seat_i][1] = i32(jnum2(po, "capacityNow"))
		}
	}
	// the battles: this seat's ongoing engagements, drawn as rings
	if bv, has := st["battles"]; has {
		if items, a_ok := bv.(json.Array); a_ok {
			for item in items {
				io, ok := item.(json.Object)
				if !ok {
					continue
				}
				ong := false
				if ov, has := io["ongoing"]; has {
					if ob, ok := ov.(json.Boolean); ok {
						ong = ob
					}
				}
				if !ong || f.n_battles >= len(f.battles) {
					continue
				}
				if av, has := io["at"]; has {
					if aa, ok := av.(json.Array); ok && len(aa) == 2 {
						f.battles[f.n_battles][0] = jnum(aa[0])
						f.battles[f.n_battles][1] = jnum(aa[1])
						f.n_battles += 1
					}
				}
			}
		}
	}
	// the fog: one seat's exploration grid per frame (the first record
	// that carries one — the viewer plays that seat's knowledge)
	if !f.has_fog {
		if mv, has := st["map"]; has {
			if mo, ok := mv.(json.Object); ok {
				if ev, has := mo["exploration"]; has {
					if eo, ok := ev.(json.Object); ok {
						f.has_fog = true
						for cell := 0; cell < 49; cell += 1 {
							f.fog[cell] = 0
						}
						for k, val in eo {
							fog_cell(f, k, jnum(val))
						}
					}
				}
			}
		}
	}
	lists := [4]string{"friendlyUnits", "enemyUnits", "friendlyBuildings", "enemyBuildings"}
	for li := 0; li < 4; li += 1 {
		kind := i32(0)
		if li >= 2 {
			kind = 1
		}
		aval, has := st[lists[li]]
		if !has {
			continue
		}
		items, a_ok := aval.(json.Array)
		if !a_ok {
			continue
		}
		for item in items {
			io, ok := item.(json.Object)
			if !ok {
				continue
			}
			x, z := f64(0), f64(0)
			if xv, has := io["x"]; has {
				x = jnum(xv)
			}
			if zv, has := io["z"]; has {
				z = jnum(zv)
			}
			worker := false
			if tv, has := io["type"]; has {
				if ts, ok := tv.(json.String); ok && ts == "worker" {
					worker = true
				}
			}
							id: i32 = 0
				if idv, has := io["id"]; has {
					id = i32(jnum(idv))
				}
				add_entity(f, x, z, kind, i32(seat_i), worker, id)
		}
	}
}

add_entity :: proc(f: ^frame, x, z: f64, kind, seat: i32, worker: bool, eid: i32) {
	// dedupe: the same (kind, rounded position) seen through another seat's
	// enemy list is the entity this frame already has
	for i := 0; i < f.n; i += 1 {
		e := &f.ents[i]
		if e.kind == kind && math.abs(e.x - x) < 0.5 && math.abs(e.z - z) < 0.5 && e.seat == seat {
			return
		}
	}
	if f.n < len(f.ents) {
		f.ents[f.n] = entity{x = x, z = z, kind = kind, seat = seat, worker = worker, eid = eid}
		f.n += 1
	}
}

// ------------------------------------------------------------------ vulkan

win_state :: struct {
	window:     ^sdl.Window,
	surface:    vk.SurfaceKHR,
	extent:     vk.Extent2D,
	format:     vk.Format,
	swapchain:  vk.SwapchainKHR,
	images:     [8]vk.Image,
	views:      [8]vk.ImageView,
	fbs:        [8]vk.Framebuffer,
	n_images:   u32,
	rp:         vk.RenderPass,
	pipe:       vk.Pipeline,
	pipe_layout: vk.PipelineLayout,
	img_avail:  vk.Semaphore,
	render_done: vk.Semaphore,
	present_q:  vk.Queue,
	pqfam:      u32,
}

vk_state :: struct {
	lib:        dynlib.Library,
	inst:       vk.Instance,
	phys:       vk.PhysicalDevice,
	device:     vk.Device,
	queue:      vk.Queue,
	qfam:       u32,
	mem_props:  vk.PhysicalDeviceMemoryProperties,
	image:      vk.Image,
	img_mem:    vk.DeviceMemory,
	img_ptr:    rawptr,
	view:       vk.ImageView,
	rp:         vk.RenderPass,
	fb:         vk.Framebuffer,
	pipe:       vk.Pipeline,
	pipe_layout: vk.PipelineLayout,
	vbuf:       vk.Buffer,
	vbuf_mem:   vk.DeviceMemory,
	vbuf_ptr:   rawptr,
	cpu_ns, gpu_ns, read_ns: i64, // the bench's phase split
	readbuf:    vk.Buffer, // the read-back target (transfer dst, host-visible)
	read_mem:   vk.DeviceMemory,
	pool:       vk.CommandPool,
	cmd:        vk.CommandBuffer,
	vs_mod:     vk.ShaderModule,
	fs_mod:     vk.ShaderModule,
}

p_get_addr: vk.ProcGetInstanceProcAddr

loader_set :: proc(p: rawptr, name: cstring) {
	pp := cast(^rawptr)p
	fnptr := p_get_addr(nil, name)
	pp^ = rawptr(fnptr)
}

read_file :: proc(path: string, buf: []byte) -> int {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return 0
	}
	n := min(len(data), len(buf))
	copy(buf[:n], data[:n])
	delete(data)
	return n
}

vk_init :: proc(s: ^vk_state) -> bool {
	lib, ok := dynlib.load_library("libvulkan.so.1")
	if !ok {
		fmt.println("face: no libvulkan")
		return false
	}
	s.lib = lib
	pGet, pok := dynlib.symbol_address(lib, "vkGetInstanceProcAddr")
	if !pok {
		fmt.println("face: no vkGetInstanceProcAddr")
		return false
	}
	p_get_addr = cast(vk.ProcGetInstanceProcAddr)pGet
	vk.load_proc_addresses_custom(loader_set)
	app := vk.ApplicationInfo{sType = .APPLICATION_INFO, pApplicationName = "war-face", apiVersion = vk.API_VERSION_1_1}
	ci := vk.InstanceCreateInfo{sType = .INSTANCE_CREATE_INFO, pApplicationInfo = &app}
	if vk.CreateInstance(&ci, nil, &s.inst) != .SUCCESS {
		fmt.println("face: CreateInstance failed")
		return false
	}
	vk.load_proc_addresses_instance(s.inst)
	n: u32
	vk.EnumeratePhysicalDevices(s.inst, &n, nil)
	if n == 0 {
		fmt.println("face: no physical devices")
		return false
	}
	devs: [8]vk.PhysicalDevice
	vk.EnumeratePhysicalDevices(s.inst, &n, raw_data(devs[:]))
	s.phys = devs[0]
	vk.GetPhysicalDeviceMemoryProperties(s.phys, &s.mem_props)
	// one queue family that does graphics
	qn: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(s.phys, &qn, nil)
	qprops := make([]vk.QueueFamilyProperties, int(qn))
	vk.GetPhysicalDeviceQueueFamilyProperties(s.phys, &qn, raw_data(qprops))
	s.qfam = 0xFFFFFFFF
	for i := 0; i < int(qn); i += 1 {
		if .GRAPHICS in qprops[i].queueFlags {
			s.qfam = u32(i)
			break
		}
	}
	delete(qprops)
	if s.qfam == 0xFFFFFFFF {
		fmt.println("face: no graphics queue")
		return false
	}
	prio := f32(1.0)
	qci := vk.DeviceQueueCreateInfo{sType = .DEVICE_QUEUE_CREATE_INFO, queueFamilyIndex = s.qfam, queueCount = 1, pQueuePriorities = &prio}
	dci := vk.DeviceCreateInfo{sType = .DEVICE_CREATE_INFO, queueCreateInfoCount = 1, pQueueCreateInfos = &qci}
	if vk.CreateDevice(s.phys, &dci, nil, &s.device) != .SUCCESS {
		fmt.println("face: CreateDevice failed")
		return false
	}
	vk.load_proc_addresses_device(s.device)
	vk.GetDeviceQueue(s.device, s.qfam, 0, &s.queue)

	// shaders
	vs_bytes := make([]byte, 4096)
	fs_bytes := make([]byte, 4096)
	vs_n := read_file("spike/face/shader.vert.spv", vs_bytes)
	fs_n := read_file("spike/face/shader.frag.spv", fs_bytes)
	if vs_n == 0 || fs_n == 0 {
		fmt.println("face: shaders missing — glslc spike/face/shader.vert -o spike/face/shader.vert.spv")
		return false
	}

	vsci := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = vs_n, pCode = cast([^]u32)raw_data(vs_bytes)}
	if vk.CreateShaderModule(s.device, &vsci, nil, &s.vs_mod) != .SUCCESS {
		fmt.println("face: vert shader failed")
		return false
	}
	fsci := vk.ShaderModuleCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, codeSize = fs_n, pCode = cast([^]u32)raw_data(fs_bytes)}
	if vk.CreateShaderModule(s.device, &fsci, nil, &s.fs_mod) != .SUCCESS {
		fmt.println("face: frag shader failed")
		return false
	}

	// the render pass: one color subpass, final layout GENERAL (we read the
	// mapped memory straight after the fence)
	att := vk.AttachmentDescription{
		format = vk.Format.R8G8B8A8_UNORM, samples = {._1}, loadOp = .CLEAR, storeOp = .STORE,
		stencilLoadOp = .DONT_CARE, stencilStoreOp = .DONT_CARE,
		initialLayout = .UNDEFINED, finalLayout = .TRANSFER_SRC_OPTIMAL,
	}
	att_ref := vk.AttachmentReference{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL}
	srp := vk.SubpassDescription{pipelineBindPoint = .GRAPHICS, colorAttachmentCount = 1, pColorAttachments = &att_ref}
	rpci := vk.RenderPassCreateInfo{sType = .RENDER_PASS_CREATE_INFO, attachmentCount = 1, pAttachments = &att, subpassCount = 1, pSubpasses = &srp}
	if vk.CreateRenderPass(s.device, &rpci, nil, &s.rp) != .SUCCESS {
		fmt.println("face: CreateRenderPass failed")
		return false
	}

	// the pipeline: dynamic viewport+scissor, push constants (16 bytes), flat quads
	pcr := vk.PushConstantRange{stageFlags = {.VERTEX}, offset = 0, size = 16}
	plci := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, pushConstantRangeCount = 1, pPushConstantRanges = &pcr}
	if vk.CreatePipelineLayout(s.device, &plci, nil, &s.pipe_layout) != .SUCCESS {
		fmt.println("face: CreatePipelineLayout failed")
		return false
	}
	bindings := [2]vk.VertexInputAttributeDescription{
		{location = 0, format = vk.Format.R32G32_SFLOAT, offset = 0},
		{location = 1, format = vk.Format.R32G32B32A32_SFLOAT, offset = 8},
	}
	bd := vk.VertexInputBindingDescription{binding = 0, stride = 24, inputRate = .VERTEX}
	vs_entry := strings.unsafe_string_to_cstring("main")
	stage_vs := vk.PipelineShaderStageCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, stage = {.VERTEX}, module = s.vs_mod, pName = vs_entry}
	stage_fs := vk.PipelineShaderStageCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, stage = {.FRAGMENT}, module = s.fs_mod, pName = vs_entry}
	pvis := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, vertexBindingDescriptionCount = 1, pVertexBindingDescriptions = &bd, vertexAttributeDescriptionCount = 2, pVertexAttributeDescriptions = raw_data(bindings[:])}
	ias := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_LIST}
	vp := vk.Viewport{width = W, height = H, maxDepth = 1}
	sc := vk.Rect2D{extent = vk.Extent2D{width = W, height = H}}
	pvps := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, pViewports = &vp, scissorCount = 1, pScissors = &sc}
	prs := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, cullMode = {}, lineWidth = 1}
	pms := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	pcb := vk.PipelineColorBlendAttachmentState{colorWriteMask = {.R, .G, .B, .A}}
	pcbs := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = 1, pAttachments = &pcb}
	stages := [2]vk.PipelineShaderStageCreateInfo{stage_vs, stage_fs}
	gpci := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2, pStages = raw_data(stages[:]),
		pVertexInputState = &pvis, pInputAssemblyState = &ias,
		pViewportState = &pvps, pRasterizationState = &prs,
		pMultisampleState = &pms, pColorBlendState = &pcbs,
		layout = s.pipe_layout, renderPass = s.rp,
	}
	gp_res := vk.CreateGraphicsPipelines(s.device, vk.PipelineCache({}), 1, &gpci, nil, &s.pipe)
	delete(vs_bytes)
	delete(fs_bytes)
	if gp_res != .SUCCESS {
		fmt.println("face: CreateGraphicsPipelines failed:", gp_res)
		return false
	}

	// the target: 800x800 RGBA8, LINEAR tiling, host-visible — the read-back
	// is a map, not a copy pass (linear + color-attachment is required)
	ici := vk.ImageCreateInfo{
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2, format = .R8G8B8A8_UNORM,
		extent = vk.Extent3D{width = W, height = H, depth = 1},
		mipLevels = 1, arrayLayers = 1,
		samples = {._1}, tiling = .LINEAR,
		usage = {.COLOR_ATTACHMENT},
		initialLayout = .UNDEFINED,
		sharingMode = .EXCLUSIVE,
	}
	if vk.CreateImage(s.device, &ici, nil, &s.image) != .SUCCESS {
		fmt.println("face: CreateImage failed")
		return false
	}
	req := vk.MemoryRequirements{}
	vk.GetImageMemoryRequirements(s.device, s.image, &req)
	idx := mem_type_for(s, req.memoryTypeBits, {.DEVICE_LOCAL})
	if idx < 0 {
		idx = mem_type_for(s, req.memoryTypeBits, {})
	}
	if idx < 0 {
		fmt.println("face: no image memory type")
		return false
	}
	ai := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = req.size, memoryTypeIndex = u32(idx)}
	if vk.AllocateMemory(s.device, &ai, nil, &s.img_mem) != .SUCCESS {
		fmt.println("face: AllocateMemory failed")
		return false
	}
	if vk.BindImageMemory(s.device, s.image, s.img_mem, 0) != .SUCCESS {
		fmt.println("face: BindImageMemory failed")
		return false
	}
	// the read-back buffer: 800x800 RGBA8, host-visible, transfer destination
	BI_RB :: W * H * 4
	rbci := vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = BI_RB, usage = {.TRANSFER_DST}, sharingMode = .EXCLUSIVE}
	if vk.CreateBuffer(s.device, &rbci, nil, &s.readbuf) != .SUCCESS {
		fmt.println("face: read-back CreateBuffer failed")
		return false
	}
	rreq := vk.MemoryRequirements{}
	vk.GetBufferMemoryRequirements(s.device, s.readbuf, &rreq)
	// cached when the device offers it: uncached mapped reads run at PCIe
	// speeds and measured 41 ms/frame — the 60 fps budget is 16.7
	ridx := mem_type_for(s, rreq.memoryTypeBits, {.HOST_VISIBLE} | {.HOST_CACHED} | {.HOST_COHERENT})
	if ridx < 0 {
		ridx = mem_type_for(s, rreq.memoryTypeBits, {.HOST_VISIBLE} | {.HOST_COHERENT})
	}
	if ridx < 0 {
		fmt.println("face: no host-visible read-back memory")
		return false
	}
	rai := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = rreq.size, memoryTypeIndex = u32(ridx)}
	if vk.AllocateMemory(s.device, &rai, nil, &s.read_mem) != .SUCCESS {
		fmt.println("face: read-back AllocateMemory failed")
		return false
	}
	if vk.BindBufferMemory(s.device, s.readbuf, s.read_mem, 0) != .SUCCESS {
		fmt.println("face: read-back BindBufferMemory failed")
		return false
	}
	vk.MapMemory(s.device, s.read_mem, 0, rreq.size, {}, &s.img_ptr)
	sub := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
	vci := vk.ImageViewCreateInfo{sType = .IMAGE_VIEW_CREATE_INFO, image = s.image, viewType = .D2, format = .R8G8B8A8_UNORM, subresourceRange = sub}
	if vk.CreateImageView(s.device, &vci, nil, &s.view) != .SUCCESS {
		fmt.println("face: CreateImageView failed")
		return false
	}
	fbci := vk.FramebufferCreateInfo{sType = .FRAMEBUFFER_CREATE_INFO, renderPass = s.rp, attachmentCount = 1, pAttachments = &s.view, width = W, height = H, layers = 1}
	if vk.CreateFramebuffer(s.device, &fbci, nil, &s.fb) != .SUCCESS {
		fmt.println("face: CreateFramebuffer failed")
		return false
	}
	// the vertex buffer: host-visible, big enough for the scene
	BI_MAX :: 1 << 20
	bci := vk.BufferCreateInfo{sType = .BUFFER_CREATE_INFO, size = BI_MAX, usage = {.VERTEX_BUFFER}, sharingMode = .EXCLUSIVE}
	if vk.CreateBuffer(s.device, &bci, nil, &s.vbuf) != .SUCCESS {
		fmt.println("face: CreateBuffer failed")
		return false
	}
	vreq := vk.MemoryRequirements{}
	vk.GetBufferMemoryRequirements(s.device, s.vbuf, &vreq)
	vidx := mem_type_for(s, vreq.memoryTypeBits, {.HOST_VISIBLE} | {.HOST_COHERENT})
	vai := vk.MemoryAllocateInfo{sType = .MEMORY_ALLOCATE_INFO, allocationSize = vreq.size, memoryTypeIndex = u32(vidx)}
	if vk.AllocateMemory(s.device, &vai, nil, &s.vbuf_mem) != .SUCCESS {
		fmt.println("face: vertex AllocateMemory failed")
		return false
	}
	vk.BindBufferMemory(s.device, s.vbuf, s.vbuf_mem, 0)
	vk.MapMemory(s.device, s.vbuf_mem, 0, vreq.size, {}, &s.vbuf_ptr)
	// the command pool + a one-shot buffer
	cpool := vk.CommandPoolCreateInfo{sType = .COMMAND_POOL_CREATE_INFO, flags = {.RESET_COMMAND_BUFFER}, queueFamilyIndex = s.qfam}
	if vk.CreateCommandPool(s.device, &cpool, nil, &s.pool) != .SUCCESS {
		fmt.println("face: CreateCommandPool failed")
		return false
	}
	cai := vk.CommandBufferAllocateInfo{sType = .COMMAND_BUFFER_ALLOCATE_INFO, commandPool = s.pool, level = .PRIMARY, commandBufferCount = 1}
	if vk.AllocateCommandBuffers(s.device, &cai, &s.cmd) != .SUCCESS {
		fmt.println("face: AllocateCommandBuffers failed")
		return false
	}
	return true
}

mem_type_for :: proc(s: ^vk_state, bits: u32, want: vk.MemoryPropertyFlags) -> i32 {
	for i := 0; i < int(s.mem_props.memoryTypeCount); i += 1 {
		if bits & (u32(1) << u32(i)) != 0 && s.mem_props.memoryTypes[i].propertyFlags & want == want {
			return i32(i)
		}
	}
	return -1
}

// draw_quads: the vertex bytes for one quad at (x,z) world, half-extent hw,
// flat color. Two triangles, 6 vertices, stride 24 bytes.
draw_quads :: proc(dst: []byte, n: ^int, x, z, hw: f32, r, g, b: f32) {
	verts := [6][6]f32{
		{x - hw, z - hw, r, g, b, 1}, {x + hw, z + hw, r, g, b, 1}, {x - hw, z + hw, r, g, b, 1},
		{x - hw, z - hw, r, g, b, 1}, {x + hw, z - hw, r, g, b, 1}, {x + hw, z + hw, r, g, b, 1},
	}
	for v in verts {
		if n^ + 24 > len(dst) {
			return
		}
		for f in v {
			// f32 little-endian bytes, exactly what the GPU reads back
			bits := u32_le(f)
			dst[n^] = byte(bits & 0xFF)
			dst[n^ + 1] = byte((bits >> 8) & 0xFF)
			dst[n^ + 2] = byte((bits >> 16) & 0xFF)
			dst[n^ + 3] = byte((bits >> 24) & 0xFF)
			n^ += 4
		}
	}
}

interp_frame :: proc(a, b: ^frame, frac: f64, out: ^frame) {
	out.n = 0
	out.nn = a.nn
	out.nodes = a.nodes
	out.fog = b.fog
	out.has_fog = b.has_fog
	out.res = b.res
	out.pop = b.pop
	out.n_battles = b.n_battles
	out.battles = b.battles
	for i := 0; i < b.n; i += 1 {
		be := &b.ents[i]
		x, z := be.x, be.z
		// units correspond by (seat, kind, id); buildings snap (they stand)
		if be.kind == 0 {
			for j := 0; j < a.n; j += 1 {
				ae := &a.ents[j]
				if ae.seat == be.seat && ae.kind == be.kind && ae.eid == be.eid && ae.eid != 0 {
					x = ae.x + (be.x - ae.x) * frac
					z = ae.z + (be.z - ae.z) * frac
					break
				}
			}
		}
		add_entity(out, x, z, be.kind, be.seat, be.worker, be.eid)
	}
}

u32_le :: proc(f: f32) -> u32 {
	return transmute(u32)f
}

// draw_text: the string at px (sx, sy) from the top-left, glyph cells 2x2 px
// per font pixel, in the colour given. Appends to the same vertex stream; the
// caller uses the HUD transform (px → NDC) in its push constants.
draw_text :: proc(dst: []byte, n: ^int, txt: string, sx, sy: f32, cr, cg, cb: f32) {
	px :: 2.0
	cx := sx
	for ch in txt {
		g := glyph_for(byte(ch))
		if g.ch != 0 {
			for row := 0; row < 7; row += 1 {
				bits := g.rows[row]
				for col := 0; col < 5; col += 1 {
					if bits & (u8(1) << u8(4 - col)) != 0 {
						x := cx + f32(col) * px
						y := sy + f32(row) * px
						// one px quad: 4 corner vertices as 2 triangles
						p := [4][2]f32{{x, y}, {x + px, y}, {x, y + px}, {x + px, y + px}}
						idx := [6]int{0, 3, 2, 0, 1, 3}
						for k := 0; k < 6; k += 1 {
							v := p[idx[k]]
							if n^ + 24 > len(dst) {
								return
							}
							vals := [6]f32{v[0], v[1], cr, cg, cb, 1}
							for ff in vals {
								bits32 := u32_le(ff)
								dst[n^] = byte(bits32 & 0xFF)
								dst[n^ + 1] = byte((bits32 >> 8) & 0xFF)
								dst[n^ + 2] = byte((bits32 >> 16) & 0xFF)
								dst[n^ + 3] = byte((bits32 >> 24) & 0xFF)
								n^ += 4
							}
						}
					}
				}
			}
		}
		cx += 6.0 * px
	}
}

glyph_for :: proc(ch: byte) -> glyph {
	for i := 0; i < len(glyph5x7); i += 1 {
		if glyph5x7[i].ch == ch {
			return glyph5x7[i]
		}
	}
	return glyph{}
}

// The 5x7 bitmap font, generated for the HUD (the glyphs the viewer
// needs: digits, A-Z, space, colon, slash, minus). One u8 per row, bit 4
// = the leftmost column.
glyph :: struct {
	ch: byte,
	rows: [7]u8,
}

glyph5x7 := [40]glyph{
	{'0', {0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110}},
{'1', {0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110}},
{'2', {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111}},
{'3', {0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110}},
{'4', {0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010}},
{'5', {0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110}},
{'6', {0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110}},
{'7', {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000}},
{'8', {0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110}},
{'9', {0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100}},
{'A', {0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001}},
{'B', {0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110}},
{'C', {0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110}},
{'D', {0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110}},
{'E', {0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111}},
{'F', {0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000}},
{'G', {0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111}},
{'H', {0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001}},
{'I', {0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110}},
{'J', {0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100}},
{'K', {0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001}},
{'L', {0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111}},
{'M', {0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001}},
{'N', {0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001}},
{'O', {0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110}},
{'P', {0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000}},
{'Q', {0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101}},
{'R', {0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001}},
{'S', {0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110}},
{'T', {0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100}},
{'U', {0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110}},
{'V', {0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100}},
{'W', {0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001}},
{'X', {0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001}},
{'Y', {0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100}},
{'Z', {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111}},
{' ', {0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000}},
{':', {0b00000, 0b00100, 0b00100, 0b00000, 0b00100, 0b00100, 0b00000}},
{'/', {0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000}},
{'-', {0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000}},
}

render_frame :: proc(s: ^vk_state, f: ^frame, cam: ^camera) -> []byte {
	// build the vertex stream: the terrain, the map's nodes, then the entities
	vbp := cast(^byte)s.vbuf_ptr
	vbuf := mem.slice_ptr(vbp, 1 << 20)
	n := 0
	// water border then the island (the true 800-world's beach ring)
	draw_quads(vbuf, &n, 0, 0, 430, 0.15, 0.25, 0.5)
	draw_quads(vbuf, &n, 0, 0, 385, 0.35, 0.55, 0.25)
	// the map's resource nodes: static scenery, colour by kind
	node_cols := [5][3]f32{
		{0.4, 0.4, 0.4},
		{0.8, 0.3, 0.8}, // food, magenta-ish
		{0.2, 0.45, 0.15}, // wood, dark green
		{0.6, 0.6, 0.65}, // stone, grey
		{0.95, 0.85, 0.2}, // gold, yellow
	}
	for i := 0; i < f.nn; i += 1 {
		nd := &f.nodes[i]
		c := node_cols[nd.kind - 2]
		draw_quads(vbuf, &n, f32(nd.x), f32(nd.z), 1.6, c.r, c.g, c.b)
	}
	// the fog: tiles under half-seen go dark, drawn over the terrain and
	// nodes but under this seat's own units (the reference's own seat is
	// never fogged for itself — the viewer keeps that honesty)
	if f.has_fog {
		tile := 800.0 / 7.0
		for row := 0; row < 7; row += 1 {
			for col := 0; col < 7; col += 1 {
				if f.fog[row * 7 + col] < 50 {
					cx := f32(-400) + (f32(col) + 0.5) * f32(tile)
					cz := f32(-400) + (f32(row) + 0.5) * f32(tile)
					draw_quads(vbuf, &n, cx, cz, f32(tile / 2), 0.02, 0.03, 0.05)
				}
			}
		}
	}
	for i := 0; i < f.n; i += 1 {
		e := &f.ents[i]
		col := CIV_COLORS[e.seat % 4]
		if e.kind == 1 {
			draw_quads(vbuf, &n, f32(e.x), f32(e.z), 7, col.r * 0.7, col.g * 0.7, col.b * 0.7)
		} else if e.worker {
			draw_quads(vbuf, &n, f32(e.x), f32(e.z), 1.8, col.r * 0.85, col.g * 0.85, col.b * 0.85)
		} else {
			draw_quads(vbuf, &n, f32(e.x), f32(e.z), 3.2, col.r, col.g, col.b)
		}
	}
	// the battles: a red frame around each ongoing engagement
	for b := 0; b < f.n_battles; b += 1 {
		bx, bz := f32(f.battles[b][0]), f32(f.battles[b][1])
		BR, hw := f32(20), f32(1.2)
		draw_quads(vbuf, &n, bx, bz - BR, hw, 0.9, 0.15, 0.1)
		draw_quads(vbuf, &n, bx, bz + BR, hw, 0.9, 0.15, 0.1)
		draw_quads(vbuf, &n, bx - BR, bz, hw, 0.9, 0.15, 0.1)
		draw_quads(vbuf, &n, bx + BR, bz, hw, 0.9, 0.15, 0.1)
	}
	// the camera: world → NDC, zoom about the centre point, y flips
	world := cam.zoom / 420.0
	pc := [4]f32{world, -world, -(cam.cx * world), (cam.cz * world)}
	// the HUD: screen-space text, appended after the world's vertices, drawn
	// with its own push constants in the same pass
	n_world := n
	hud := fmt.aprintf("TURN {}", f.turn)
	draw_text(vbuf, &n, hud, 4, 4, 0.9, 0.9, 0.9)
	delete(hud)
	civ_tag := [4]string{"E", "G", "P", "Y"}
	for seat := 0; seat < 4; seat += 1 {
		line := fmt.aprintf("{} F:{} W:{} S:{} G:{} P:{}/{}", civ_tag[seat], f.res[seat][0], f.res[seat][1], f.res[seat][2], f.res[seat][3], f.pop[seat][0], f.pop[seat][1])
		col := CIV_COLORS[seat % 4]
		draw_text(vbuf, &n, line, f32(4 + seat * 190), f32(H - 20), col.r, col.g, col.b)
		delete(line)
	}
	hud_pc := [4]f32{2.0 / f32(W), 2.0 / f32(H), -1, -1}
	rec_start := time.tick_now()
	vk.ResetCommandBuffer(s.cmd, {})
	cbi := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO}
	vk.BeginCommandBuffer(s.cmd, &cbi)
	rpbi := vk.RenderPassBeginInfo{
		sType = .RENDER_PASS_BEGIN_INFO, renderPass = s.rp, framebuffer = s.fb,
		renderArea = vk.Rect2D{extent = vk.Extent2D{width = W, height = H}},
	}
	clear := vk.ClearValue{color = vk.ClearColorValue{float32 = [4]f32{0.08, 0.10, 0.14, 1}}}
	rpbi.clearValueCount = 1
	rpbi.pClearValues = &clear
	vk.CmdBeginRenderPass(s.cmd, &rpbi, .INLINE)
	vk.CmdBindPipeline(s.cmd, .GRAPHICS, s.pipe)
	offsets := [1]vk.DeviceSize{0}
	vbuf_h := s.vbuf
	vk.CmdBindVertexBuffers(s.cmd, 0, 1, &vbuf_h, raw_data(offsets[:]))
	vk.CmdPushConstants(s.cmd, s.pipe_layout, {.VERTEX}, 0, 16, &pc)
	vk.CmdDraw(s.cmd, u32(n_world / 6), 1, 0, 0)
	vk.CmdPushConstants(s.cmd, s.pipe_layout, {.VERTEX}, 0, 16, &hud_pc)
	vk.CmdDraw(s.cmd, u32((n - n_world) / 6), 1, 0, 0)
	vk.CmdEndRenderPass(s.cmd)
	rec_end := time.tick_now()
	region := vk.BufferImageCopy{
		bufferOffset = 0,
		imageSubresource = vk.ImageSubresourceLayers{aspectMask = {.COLOR}, mipLevel = 0, baseArrayLayer = 0, layerCount = 1},
		imageExtent = vk.Extent3D{width = W, height = H, depth = 1},
	}
	vk.CmdCopyImageToBuffer(s.cmd, s.image, .TRANSFER_SRC_OPTIMAL, s.readbuf, 1, &region)
	vk.EndCommandBuffer(s.cmd)
	si := vk.SubmitInfo{sType = .SUBMIT_INFO, commandBufferCount = 1, pCommandBuffers = &s.cmd}
	vk.QueueSubmit(s.queue, 1, &si, vk.Fence({}))
	vk.QueueWaitIdle(s.queue)
	t2 := time.tick_now()
	s.gpu_ns += t2._nsec - rec_end._nsec
	rows := make([]byte, H * W * 4)
	ipb := cast(^byte)s.img_ptr
	copy(rows, mem.slice_ptr(ipb, H * W * 4))
	t3 := time.tick_now()
	s.read_ns += t3._nsec - t2._nsec
	return rows
}

vk_shutdown :: proc(s: ^vk_state) {
	vk.DeviceWaitIdle(s.device)
	vk.DestroyCommandPool(s.device, s.pool, nil)
	vk.DestroyBuffer(s.device, s.vbuf, nil)
	vk.FreeMemory(s.device, s.vbuf_mem, nil)
	vk.DestroyBuffer(s.device, s.readbuf, nil)
	vk.FreeMemory(s.device, s.read_mem, nil)
	vk.DestroyFramebuffer(s.device, s.fb, nil)
	vk.DestroyImageView(s.device, s.view, nil)
	vk.UnmapMemory(s.device, s.img_mem)
	vk.FreeMemory(s.device, s.img_mem, nil)
	vk.DestroyImage(s.device, s.image, nil)
	vk.DestroyPipeline(s.device, s.pipe, nil)
	vk.DestroyPipelineLayout(s.device, s.pipe_layout, nil)
	vk.DestroyRenderPass(s.device, s.rp, nil)
	vk.DestroyShaderModule(s.device, s.vs_mod, nil)
	vk.DestroyShaderModule(s.device, s.fs_mod, nil)
	vk.DestroyDevice(s.device, nil)
	vk.DestroyInstance(s.inst, nil)
	_ = s.lib // the loader stays loaded for the process lifetime
}

// -------------------------------------------------------------------- main

main :: proc() {
	// the leak discipline the daemon will live by (gate 7's shape): the whole
	// run under a tracking allocator, the balance named at exit — Odin procs
	// do not capture, so the body is a called proc, not a deferred block
	heap := context.allocator
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, heap)
	context.allocator = mem.tracking_allocator(&tracker)
	face_run()
	context.allocator = heap
	if tracker.total_allocation_count != tracker.total_free_count {
		fmt.println("FACE LEAKS:", tracker.total_allocation_count, "allocations vs", tracker.total_free_count, "frees,", tracker.current_memory_allocated, "bytes live")
		shown := 0
		for _, entry in tracker.allocation_map {
			fmt.println("  leaked", entry.size, "bytes at", entry.location.file_path, entry.location.line)
			shown += 1
			if shown >= 5 {
				break
			}
		}
		os.exit(1)
	}
	fmt.println("face memory balanced:", tracker.total_allocation_count, "allocations, 0 live")
}

face_present :: proc(vs: ^vk_state, frames: []frame, lines: []string, max_turn: int, cam: ^camera, png_prefix: string, bench: bool, at_frac: f64, one_turn: int) {
	sample := [12]int{10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120}
	f := &frames[1]
	if bench {
		// every turn, timed: the ms/frame the milestone's 60 fps needs
		start := time.tick_now()
		rendered := 0
		for turn := 1; turn <= 120; turn += 1 {
			rows := render_frame(vs, &frames[turn], cam)
			delete(rows)
			rendered += 1
		}
		e2 := time.tick_now()
		ns := e2._nsec - start._nsec
		fmt.println("bench: rendered", rendered, "frames in", f64(ns) / 1e6, "ms —", f64(ns) / 1e6 / f64(rendered), "ms/frame")
		fmt.println("  submit+gpu wait:", f64(vs.gpu_ns) / 1e6, "ms; read map:", f64(vs.read_ns) / 1e6, "ms")
		return
	}
	if at_frac >= 1 {
		// the interpolated frame: between floor(at) and floor(at)+1, at the
		// fraction — the smooth-playback primitive the window's playback uses
		lo := int(at_frac)
		hi := lo + 1
		if hi <= max_turn {
			frac := at_frac - f64(lo)
			interpolated: frame
			interpolated.turn = lo
			interpolated.fog = frames[hi].fog
			interpolated.has_fog = frames[hi].has_fog
			interpolated.res = frames[hi].res
			interpolated.pop = frames[hi].pop
			interpolated.n_battles = frames[hi].n_battles
			interpolated.battles = frames[hi].battles
			interpolated.nn = frames[lo].nn
			interpolated.nodes = frames[lo].nodes
			for i := 0; i < frames[hi].n; i += 1 {
				be := &frames[hi].ents[i]
				x, z := be.x, be.z
				if be.kind == 0 {
					for j := 0; j < frames[lo].n; j += 1 {
						ae := &frames[lo].ents[j]
						if ae.seat == be.seat && ae.kind == be.kind && ae.eid == be.eid && ae.eid != 0 {
							x = ae.x + (be.x - ae.x) * frac
							z = ae.z + (be.z - ae.z) * frac
							break
						}
					}
				}
				add_entity(&interpolated, x, z, be.kind, be.seat, be.worker, be.eid)
			}
			f = &interpolated
			rows := render_frame(vs, f, cam)
			fmt.println("frame at", at_frac, "entities", f.n, "fnv1a", fnv(rows))
			if png_prefix != "" {
				pp := fmt.aprintf("{}-at{}.ppm", png_prefix, at_frac)
				write_ppm(pp, rows)
				delete(pp)
			}
			delete(rows)
			return
		}
	}
	if one_turn > 0 {
		f = &frames[one_turn]
		rows := render_frame(vs, f, cam)
		fmt.println("frame turn", f.turn, "entities", f.n, "battles", f.n_battles, "fnv1a", fnv(rows))
		if png_prefix != "" {
			pp := fmt.aprintf("{}-t{}.ppm", png_prefix, f.turn)
			write_ppm(pp, rows)
			delete(pp)
		}
		delete(rows)
		return
	}
	for si := 0; si < len(sample); si += 1 {
		f = &frames[sample[si]]
		rows := render_frame(vs, f, cam)
		dg := fmt.aprintf("{}{}{}", fnv(rows), "", "")
			fmt.println("frame turn", f.turn, "entities", f.n, "fnv1a", dg)
			delete(dg)
		if png_prefix != "" {
			write_ppm(fmt.aprintf("{}-t{}.ppm", png_prefix, f.turn), rows)
		}
		delete(rows)
	}
}

face_run :: proc() {
	args := os.args
	path := "golden/stream-1m.jsonl"
	png_prefix := ""
	bench := false
	window_mode := false
	one_turn := -1
	at_frac := f64(-1)
	if len(args) >= 2 {
		path = args[1]
	}
	cam := camera{zoom = 1, cx = 0, cz = 0}
	for a := 2; a < len(args); a += 1 {
		if args[a] == "--png" && a + 1 < len(args) {
			a += 1
			png_prefix = args[a]
		} else if args[a] == "--zoom" && a + 1 < len(args) {
			a += 1
			if v, ok := strconv.parse_f64(args[a]); ok {
				cam.zoom = f32(v)
			}
		} else if args[a] == "--cx" && a + 1 < len(args) {
			a += 1
			if v, ok := strconv.parse_f64(args[a]); ok {
				cam.cx = f32(v)
			}
		} else if args[a] == "--cz" && a + 1 < len(args) {
			a += 1
			if v, ok := strconv.parse_f64(args[a]); ok {
				cam.cz = f32(v)
			}
		} else if args[a] == "--window" {
			window_mode = true
		} else if args[a] == "--bench" {
			bench = true
		} else if args[a] == "--at" && a + 1 < len(args) {
			a += 1
			if v, ok := strconv.parse_f64(args[a]); ok {
				at_frac = v
			}
		} else if args[a] == "--turn" && a + 1 < len(args) {
			a += 1
			if v, ok := strconv.parse_int(args[a]); ok {
				one_turn = int(v)
			}
		}
	}
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		fmt.println("face: cannot read", path)
		os.exit(1)
	}
	lines := strings.split(string(data), "\n")
	// the sampled turns: every 10 turns across the minute (turn 10..120)
	sample := [12]int{10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120}
	if bench {
		// the 60 fps question, measured: every turn of the corpus, timed
		for i := 1; i <= 12; i += 1 {
			sample[i - 1] = i * 10
		}
	}
	if bench {
		// the 60 fps question, measured: every turn of the corpus, timed
		for i := 1; i <= 12; i += 1 {
			sample[i - 1] = i * 10
		}
	}
	vs: vk_state
	if !vk_init(&vs) {
		os.exit(1)
	}
	defer vk_shutdown(&vs)
	ws: win_state
	if window_mode {
		// the presented face: the same renderer, a real (or virtual) display.
		// The parse-scale work stays; the swapchain's own init follows.
		if !win_init(&vs, &ws, 1024, 768) {
			os.exit(1)
		}
		frames := make([]frame, 121)
		seen2 := make([]bool, 121)
		for line in lines {
			if len(line) == 0 {
				continue
			}
			v, err := json.parse_string(line)
			if err != nil {
				continue
			}
			if obj, ok := v.(json.Object); ok {
				if tv, has := obj["turn"]; has {
					tn := int(jnum(tv))
					if tn >= 1 && tn <= 120 {
						if !seen2[tn] {
							seen2[tn] = true
							frames[tn].n = 0
							frames[tn].n_battles = 0
							frames[tn].has_fog = false
							frames[tn].nn = 0
						}
						scene_fill(v, &frames[tn])
						frames[tn].turn = tn
					} else {
						if tv2, has := obj["type"]; has {
							if ts, ok := tv2.(json.String); ok && ts == "map" {
								if rv, has := obj["resources"]; has {
									if items, a_ok := rv.(json.Array); a_ok {
										for item in items {
											io, ok := item.(json.Object)
											if !ok {
												continue
											}
											x, z := jnum2(io, "x"), jnum2(io, "z")
											nt: i32 = 0
											if ttv, has := io["t"]; has {
												if tts, ok := ttv.(json.String); ok {
													nt = node_kind(tts)
												}
											}
											for ti := 1; ti <= 120; ti += 1 {
												if frames[ti].nn < len(frames[ti].nodes) {
													frames[ti].nodes[frames[ti].nn] = entity{x = x, z = z, kind = 2 + nt, seat = 0}
													frames[ti].nn += 1
												}
											}
										}
									}
								}
							}
						}
					}
				}
			}
			json.destroy_value(v)
		}
		win_run(&vs, &ws, frames, &cam)
		delete(frames)
		delete(seen2)
		delete(lines)
		delete(data)
		sdl.Quit()
		return
	}
	// the transcript parses ONCE: the scenes for the whole match, the map line
	// folded into every frame (scene_at's 600-line JSON walk is the slow part;
	// the GPU must be measured alone)
	max_turn := 120
	if one_turn > max_turn {
		max_turn = one_turn
	}
	frames := make([]frame, max_turn + 1)
	seen := make([]bool, max_turn + 1)
	// one pass: each line parsed once and routed to its own turn's frame —
	// the per-turn scan over the whole file was the slow path at 10m
	for line in lines {
		if len(line) == 0 {
			continue
		}
		v, err := json.parse_string(line)
		if err != nil {
			continue
		}
		if obj, ok := v.(json.Object); ok {
			if tv, has := obj["turn"]; has {
				tn := int(jnum(tv))
				if tn >= 1 && tn <= max_turn {
					if !seen[tn] {
						seen[tn] = true
						frames[tn].n = 0
						frames[tn].n_battles = 0
						frames[tn].has_fog = false
						frames[tn].nn = 0
					}
					scene_fill(v, &frames[tn])
					frames[tn].turn = tn
				}
			} else {
				if tv2, has := obj["type"]; has {
					if ts, ok := tv2.(json.String); ok && ts == "map" {
						if rv, has := obj["resources"]; has {
							if items, a_ok := rv.(json.Array); a_ok {
								for item in items {
									io, ok := item.(json.Object)
									if !ok {
										continue
									}
									x, z := jnum2(io, "x"), jnum2(io, "z")
									nt: i32 = 0
									if ttv, has := io["t"]; has {
										if tts, ok := ttv.(json.String); ok {
											nt = node_kind(tts)
										}
									}
									for ti := 1; ti <= max_turn; ti += 1 {
										if frames[ti].nn < len(frames[ti].nodes) {
											frames[ti].nodes[frames[ti].nn] = entity{x = x, z = z, kind = 2 + nt, seat = 0}
											frames[ti].nn += 1
										}
									}
								}
							}
						}
					}
				}
			}
		}
		json.destroy_value(v)
	}
	f := &frames[1]
	face_present(&vs, frames, lines, max_turn, &cam, png_prefix, bench, at_frac, one_turn)
	delete(lines)
	delete(data)
	delete(frames)
	delete(seen)
}

write_ppm :: proc(path: string, rows: []byte) {
	// rows is RGBA; PPM is RGB
	rgb := make([]byte, W * H * 3)
	for i := 0; i < W * H; i += 1 {
		rgb[i * 3] = rows[i * 4]
		rgb[i * 3 + 1] = rows[i * 4 + 1]
		rgb[i * 3 + 2] = rows[i * 4 + 2]
	}
	f, cerr := os.create(path)
	if cerr != nil {
		return
	}
	fmt.fprintln(f, "P6", W, H, 255)
	os.write(f, rgb)
	os.close(f)
	delete(rgb)
}

// ---- the window: SDL2 surface + swapchain, the replay at 60 fps -----------
// The increment this box could not verify until Xvfb: the same renderer, the
// same scene build, presented to a real (virtual) display. Playback runs at
// 10 turns/s with the interpolation primitive filling the 60 Hz frames.
win_init :: proc(vs: ^vk_state, w: ^win_state, width, height: i32) -> bool {
	if sdl.Init(sdl.INIT_VIDEO) != 0 {
		fmt.println("window: SDL_Init failed:", sdl.GetError())
		return false
	}
	w.window = sdl.CreateWindow("war-face", 100, 100, width, height, sdl.WINDOW_SHOWN | sdl.WINDOW_VULKAN)
	if w.window == nil {
		fmt.println("window: CreateWindow failed:", sdl.GetError())
		return false
	}
	// the instance: SDL names the extensions the surface needs
	n_ext: u32
	sdl.Vulkan_GetInstanceExtensions(w.window, &n_ext, nil)
	ext_names: [8]cstring
	sdl.Vulkan_GetInstanceExtensions(w.window, &n_ext, raw_data(ext_names[:]))
	app := vk.ApplicationInfo{sType = .APPLICATION_INFO, pApplicationName = "war-face", apiVersion = vk.API_VERSION_1_1}
	ci := vk.InstanceCreateInfo{sType = .INSTANCE_CREATE_INFO, pApplicationInfo = &app, enabledExtensionCount = n_ext, ppEnabledExtensionNames = raw_data(ext_names[:])}
	if vk.CreateInstance(&ci, nil, &vs.inst) != .SUCCESS {
		fmt.println("window: CreateInstance failed")
		return false
	}
	vk.load_proc_addresses_instance(vs.inst)
	if !sdl.Vulkan_CreateSurface(w.window, vs.inst, &w.surface) {
		fmt.println("window: CreateSurface failed:", sdl.GetError())
		return false
	}
	// the device: a queue family that both draws and presents
	n: u32
	vk.EnumeratePhysicalDevices(vs.inst, &n, nil)
	devs: [8]vk.PhysicalDevice
	vk.EnumeratePhysicalDevices(vs.inst, &n, raw_data(devs[:]))
	vk.GetPhysicalDeviceMemoryProperties(devs[0], &vs.mem_props)
	vs.phys = devs[0]
	qn: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(vs.phys, &qn, nil)
	qprops := make([]vk.QueueFamilyProperties, int(qn))
	vk.GetPhysicalDeviceQueueFamilyProperties(vs.phys, &qn, raw_data(qprops))
	defer delete(qprops)
	found := false
	for i := 0; i < int(qn); i += 1 {
		if .GRAPHICS in qprops[i].queueFlags {
			sup: b32 = false
			vk.GetPhysicalDeviceSurfaceSupportKHR(vs.phys, u32(i), w.surface, &sup)
			if sup {
				vs.qfam = u32(i)
				w.pqfam = u32(i)
				found = true
				break
			}
		}
	}
	if !found {
		fmt.println("window: no graphics+present queue")
		return false
	}
	prio := f32(1.0)
	qci := vk.DeviceQueueCreateInfo{sType = .DEVICE_QUEUE_CREATE_INFO, queueFamilyIndex = vs.qfam, queueCount = 1, pQueuePriorities = &prio}
	ext_c, _ := strings.clone_to_cstring("VK_KHR_swapchain")
	defer delete(ext_c)
	ext_names_slice := [1]cstring{ext_c}
	dci := vk.DeviceCreateInfo{sType = .DEVICE_CREATE_INFO, queueCreateInfoCount = 1, pQueueCreateInfos = &qci, enabledExtensionCount = 1, ppEnabledExtensionNames = cast([^]cstring)&ext_names_slice}
	if vk.CreateDevice(vs.phys, &dci, nil, &vs.device) != .SUCCESS {
		fmt.println("window: CreateDevice failed")
		return false
	}
	vk.load_proc_addresses_device(vs.device)
	vk.GetDeviceQueue(vs.device, vs.qfam, 0, &vs.queue)
	vk.GetDeviceQueue(vs.device, w.pqfam, 0, &w.present_q)
	// the swapchain: FIFO, the surface's current extent and format
	caps := vk.SurfaceCapabilitiesKHR{}
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(vs.phys, w.surface, &caps)
	w.extent = caps.currentExtent
	nf: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(vs.phys, w.surface, &nf, nil)
	fmts := make([]vk.SurfaceFormatKHR, int(nf))
	vk.GetPhysicalDeviceSurfaceFormatsKHR(vs.phys, w.surface, &nf, raw_data(fmts))
	w.format = fmts[0].format
	if nf > 1 {
		for i := 0; i < int(nf); i += 1 {
			if fmts[i].format == .B8G8R8A8_UNORM || fmts[i].format == .R8G8B8A8_UNORM {
				w.format = fmts[i].format
				break
			}
		}
	}
	delete(fmts)
	sci := vk.SwapchainCreateInfoKHR{
		sType = .SWAPCHAIN_CREATE_INFO_KHR,
		surface = w.surface, minImageCount = max(2, caps.minImageCount),
		imageFormat = w.format, imageColorSpace = fmts[0].colorSpace,
		imageExtent = w.extent, imageArrayLayers = 1,
		imageUsage = {.COLOR_ATTACHMENT}, imageSharingMode = .EXCLUSIVE,
		preTransform = caps.currentTransform, compositeAlpha = {.OPAQUE},
		presentMode = .FIFO, clipped = true,
	}
	if vk.CreateSwapchainKHR(vs.device, &sci, nil, &w.swapchain) != .SUCCESS {
		fmt.println("window: CreateSwapchainKHR failed")
		return false
	}
	vk.GetSwapchainImagesKHR(vs.device, w.swapchain, &w.n_images, nil)
	vk.GetSwapchainImagesKHR(vs.device, w.swapchain, &w.n_images, raw_data(w.images[:]))
	// the render pass: PRESENT_SRC at the end
	att := vk.AttachmentDescription{
		format = w.format, samples = {._1}, loadOp = .CLEAR, storeOp = .STORE,
		stencilLoadOp = .DONT_CARE, stencilStoreOp = .DONT_CARE,
		initialLayout = .UNDEFINED, finalLayout = .PRESENT_SRC_KHR,
	}
	att_ref := vk.AttachmentReference{attachment = 0, layout = .COLOR_ATTACHMENT_OPTIMAL}
	srp := vk.SubpassDescription{pipelineBindPoint = .GRAPHICS, colorAttachmentCount = 1, pColorAttachments = &att_ref}
	rpci := vk.RenderPassCreateInfo{sType = .RENDER_PASS_CREATE_INFO, attachmentCount = 1, pAttachments = &att, subpassCount = 1, pSubpasses = &srp}
	if vk.CreateRenderPass(vs.device, &rpci, nil, &w.rp) != .SUCCESS {
		fmt.println("window: CreateRenderPass failed")
		return false
	}
	// the pipeline: the same shaders, the window's render pass
	pcr := vk.PushConstantRange{stageFlags = {.VERTEX}, offset = 0, size = 16}
	plci := vk.PipelineLayoutCreateInfo{sType = .PIPELINE_LAYOUT_CREATE_INFO, pushConstantRangeCount = 1, pPushConstantRanges = &pcr}
	if vk.CreatePipelineLayout(vs.device, &plci, nil, &w.pipe_layout) != .SUCCESS {
		fmt.println("window: CreatePipelineLayout failed")
		return false
	}
	bindings := [2]vk.VertexInputAttributeDescription{
		{location = 0, format = .R32G32_SFLOAT, offset = 0},
		{location = 1, format = .R32G32B32A32_SFLOAT, offset = 8},
	}
	bd := vk.VertexInputBindingDescription{binding = 0, stride = 24, inputRate = .VERTEX}
	vs_entry := strings.unsafe_string_to_cstring("main")
	stage_vs := vk.PipelineShaderStageCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, stage = {.VERTEX}, module = vs.vs_mod, pName = vs_entry}
	stage_fs := vk.PipelineShaderStageCreateInfo{sType = .SHADER_MODULE_CREATE_INFO, stage = {.FRAGMENT}, module = vs.fs_mod, pName = vs_entry}
	pvis := vk.PipelineVertexInputStateCreateInfo{sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, vertexBindingDescriptionCount = 1, pVertexBindingDescriptions = &bd, vertexAttributeDescriptionCount = 2, pVertexAttributeDescriptions = raw_data(bindings[:])}
	ias := vk.PipelineInputAssemblyStateCreateInfo{sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, topology = .TRIANGLE_LIST}
	vp := vk.Viewport{width = f32(w.extent.width), height = f32(w.extent.height), maxDepth = 1}
	sc := vk.Rect2D{extent = w.extent}
	pvps := vk.PipelineViewportStateCreateInfo{sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO, viewportCount = 1, pViewports = &vp, scissorCount = 1, pScissors = &sc}
	prs := vk.PipelineRasterizationStateCreateInfo{sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO, polygonMode = .FILL, lineWidth = 1}
	pms := vk.PipelineMultisampleStateCreateInfo{sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, rasterizationSamples = {._1}}
	pcb := vk.PipelineColorBlendAttachmentState{colorWriteMask = {.R, .G, .B, .A}}
	pcbs := vk.PipelineColorBlendStateCreateInfo{sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, attachmentCount = 1, pAttachments = &pcb}
	stages := [2]vk.PipelineShaderStageCreateInfo{stage_vs, stage_fs}
	gpci := vk.GraphicsPipelineCreateInfo{
		sType = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2, pStages = raw_data(stages[:]),
		pVertexInputState = &pvis, pInputAssemblyState = &ias,
		pViewportState = &pvps, pRasterizationState = &prs,
		pMultisampleState = &pms, pColorBlendState = &pcbs,
		layout = w.pipe_layout, renderPass = w.rp,
	}
	if vk.CreateGraphicsPipelines(vs.device, vk.PipelineCache({}), 1, &gpci, nil, &w.pipe) != .SUCCESS {
		fmt.println("window: CreateGraphicsPipelines failed")
		return false
	}
	for i := 0; i < int(w.n_images); i += 1 {
		sub := vk.ImageSubresourceRange{aspectMask = {.COLOR}, levelCount = 1, layerCount = 1}
		vci := vk.ImageViewCreateInfo{sType = .IMAGE_VIEW_CREATE_INFO, image = w.images[i], viewType = .D2, format = w.format, subresourceRange = sub}
		if vk.CreateImageView(vs.device, &vci, nil, &w.views[i]) != .SUCCESS {
			fmt.println("window: CreateImageView failed")
			return false
		}
		fbci := vk.FramebufferCreateInfo{sType = .FRAMEBUFFER_CREATE_INFO, renderPass = w.rp, attachmentCount = 1, pAttachments = &w.views[i], width = w.extent.width, height = w.extent.height, layers = 1}
		if vk.CreateFramebuffer(vs.device, &fbci, nil, &w.fbs[i]) != .SUCCESS {
			fmt.println("window: CreateFramebuffer failed")
			return false
		}
	}
	sci_sem := vk.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO}
	vk.CreateSemaphore(vs.device, &sci_sem, nil, &w.img_avail)
	vk.CreateSemaphore(vs.device, &sci_sem, nil, &w.render_done)
	return true
}

// win_run: the replay at 60 fps — 10 turns/s, the interpolation primitive
// filling the frames between whole turns; ESC quits, space pauses, A/D step
// one turn, W/S zooms.
win_run :: proc(vs: ^vk_state, w: ^win_state, frames: []frame, cam: ^camera) {
	vbuf := mem.slice_ptr(cast(^byte)vs.vbuf_ptr, 1 << 20)
	turn := 1
	frac := f64(0)
	paused := false
	running := true
	presented := 0
	last := sdl.GetTicks()
	for running {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				running = false
			case .KEYDOWN:
				kb := ev.key
				if kb.keysym.sym == .ESCAPE {
					running = false
				} else if kb.keysym.sym == .SPACE {
					paused = !paused
				} else if kb.keysym.sym == .A {
					turn = max(1, turn - 1)
					frac = 0
				} else if kb.keysym.sym == .D {
					turn = min(len(frames) - 2, turn + 1)
					frac = 0
				} else if kb.keysym.sym == .W {
					cam.zoom *= 1.25
				} else if kb.keysym.sym == .S {
					cam.zoom = max(0.25, cam.zoom / 1.25)
				}
			case:
			}
		}
		if !paused {
			now := sdl.GetTicks()
			elapsed := f64(now - last)
			last = now
			frac += elapsed / 100.0 // 10 turns/s
			for frac >= 1 {
				frac -= 1
				turn += 1
				if turn >= len(frames) - 1 {
					turn = 1
				}
			}
		}
		// the interpolated scene between `turn` and `turn+1`
		interpolated: frame
		interpolated.turn = turn
		interpolated.fog = frames[turn + 1].fog
		interpolated.has_fog = frames[turn + 1].has_fog
		interpolated.res = frames[turn + 1].res
		interpolated.pop = frames[turn + 1].pop
		interpolated.n_battles = frames[turn + 1].n_battles
		interpolated.battles = frames[turn + 1].battles
		interpolated.nn = frames[turn].nn
		interpolated.nodes = frames[turn].nodes
		for i := 0; i < frames[turn + 1].n; i += 1 {
			be := &frames[turn + 1].ents[i]
			x, z := be.x, be.z
			if be.kind == 0 {
				for j := 0; j < frames[turn].n; j += 1 {
					ae := &frames[turn].ents[j]
					if ae.seat == be.seat && ae.kind == be.kind && ae.eid == be.eid && ae.eid != 0 {
						x = ae.x + (be.x - ae.x) * frac
						z = ae.z + (be.z - ae.z) * frac
						break
					}
				}
			}
			add_entity(&interpolated, x, z, be.kind, be.seat, be.worker, be.eid)
		}
		// the vertex stream: the world, then the HUD
		n := 0
		draw_quads(vbuf, &n, 0, 0, 430, 0.15, 0.25, 0.5)
		draw_quads(vbuf, &n, 0, 0, 385, 0.35, 0.55, 0.25)
		node_cols := [5][3]f32{{0.4, 0.4, 0.4}, {0.8, 0.3, 0.8}, {0.2, 0.45, 0.15}, {0.6, 0.6, 0.65}, {0.95, 0.85, 0.2}}
		for i := 0; i < interpolated.nn; i += 1 {
			nd := &interpolated.nodes[i]
			c := node_cols[nd.kind - 2]
			draw_quads(vbuf, &n, f32(nd.x), f32(nd.z), 1.6, c.r, c.g, c.b)
		}
		if interpolated.has_fog {
			tile := 800.0 / 7.0
			for row := 0; row < 7; row += 1 {
				for col := 0; col < 7; col += 1 {
					if interpolated.fog[row * 7 + col] < 50 {
						fcx := f32(-400) + (f32(col) + 0.5) * f32(tile)
						fcz := f32(-400) + (f32(row) + 0.5) * f32(tile)
						draw_quads(vbuf, &n, fcx, fcz, f32(tile / 2), 0.02, 0.03, 0.05)
					}
				}
			}
		}
		for i := 0; i < interpolated.n; i += 1 {
			e := &interpolated.ents[i]
			col := CIV_COLORS[e.seat % 4]
			if e.kind == 1 {
				draw_quads(vbuf, &n, f32(e.x), f32(e.z), 7, col.r * 0.7, col.g * 0.7, col.b * 0.7)
			} else if e.worker {
				draw_quads(vbuf, &n, f32(e.x), f32(e.z), 1.8, col.r * 0.85, col.g * 0.85, col.b * 0.85)
			} else {
				draw_quads(vbuf, &n, f32(e.x), f32(e.z), 3.2, col.r, col.g, col.b)
			}
		}
		for b := 0; b < interpolated.n_battles; b += 1 {
			bx, bz := f32(interpolated.battles[b][0]), f32(interpolated.battles[b][1])
			BR, hw := f32(20), f32(1.2)
			draw_quads(vbuf, &n, bx, bz - BR, hw, 0.9, 0.15, 0.1)
			draw_quads(vbuf, &n, bx, bz + BR, hw, 0.9, 0.15, 0.1)
			draw_quads(vbuf, &n, bx - BR, bz, hw, 0.9, 0.15, 0.1)
			draw_quads(vbuf, &n, bx + BR, bz, hw, 0.9, 0.15, 0.1)
		}
		n_world := n
		hud := fmt.aprintf("TURN {}", interpolated.turn)
		draw_text(vbuf, &n, hud, 4, 4, 0.9, 0.9, 0.9)
		delete(hud)
		civ_tag := [4]string{"E", "G", "P", "Y"}
		for seat := 0; seat < 4; seat += 1 {
			line := fmt.aprintf("{} F:{} W:{} S:{} G:{} P:{}/{}", civ_tag[seat], interpolated.res[seat][0], interpolated.res[seat][1], interpolated.res[seat][2], interpolated.res[seat][3], interpolated.pop[seat][0], interpolated.pop[seat][1])
			col := CIV_COLORS[seat % 4]
			draw_text(vbuf, &n, line, f32(4 + seat * 190), 4, col.r, col.g, col.b)
			delete(line)
		}
		world := cam.zoom / 420.0
		pc := [4]f32{world, -world, -(cam.cx * world), (cam.cz * world)}
		hud_pc := [4]f32{2.0 / f32(w.extent.width), 2.0 / f32(w.extent.height), -1, -1}
		img: u32
		if vk.AcquireNextImageKHR(vs.device, w.swapchain, u64(1e9), w.img_avail, vk.Fence({}), &img) != .SUCCESS {
			continue
		}
		vk.ResetCommandBuffer(vs.cmd, {})
		cbi := vk.CommandBufferBeginInfo{sType = .COMMAND_BUFFER_BEGIN_INFO}
		vk.BeginCommandBuffer(vs.cmd, &cbi)
		rpbi := vk.RenderPassBeginInfo{
			sType = .RENDER_PASS_BEGIN_INFO, renderPass = w.rp, framebuffer = w.fbs[img],
			renderArea = vk.Rect2D{extent = w.extent},
		}
		clear := vk.ClearValue{color = vk.ClearColorValue{float32 = [4]f32{0.08, 0.10, 0.14, 1}}}
		rpbi.clearValueCount = 1
		rpbi.pClearValues = &clear
		vk.CmdBeginRenderPass(vs.cmd, &rpbi, .INLINE)
		vk.CmdBindPipeline(vs.cmd, .GRAPHICS, w.pipe)
		vbuf_h := vs.vbuf
		offsets := [1]vk.DeviceSize{0}
		vk.CmdBindVertexBuffers(vs.cmd, 0, 1, &vbuf_h, raw_data(offsets[:]))
		vk.CmdPushConstants(vs.cmd, w.pipe_layout, {.VERTEX}, 0, 16, &pc)
		vk.CmdDraw(vs.cmd, u32(n_world / 6), 1, 0, 0)
		vk.CmdPushConstants(vs.cmd, w.pipe_layout, {.VERTEX}, 0, 16, &hud_pc)
		vk.CmdDraw(vs.cmd, u32((n - n_world) / 6), 1, 0, 0)
		vk.CmdEndRenderPass(vs.cmd)
		vk.EndCommandBuffer(vs.cmd)
		wait_stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
		si := vk.SubmitInfo{
			sType = .SUBMIT_INFO,
			waitSemaphoreCount = 1, pWaitSemaphores = &w.img_avail,
			pWaitDstStageMask = &wait_stage,
			signalSemaphoreCount = 1, pSignalSemaphores = &w.render_done,
			commandBufferCount = 1, pCommandBuffers = &vs.cmd,
		}
		vk.QueueSubmit(vs.queue, 1, &si, vk.Fence({}))
		present := [1]vk.SwapchainKHR{w.swapchain}
		pci := vk.PresentInfoKHR{
			sType = .PRESENT_INFO_KHR,
			waitSemaphoreCount = 1, pWaitSemaphores = &w.render_done,
			swapchainCount = 1, pSwapchains = raw_data(present[:]),
			pImageIndices = &img,
		}
		vk.QueuePresentKHR(w.present_q, &pci)
		vk.QueueWaitIdle(w.present_q)
		presented += 1
	}
	fmt.println("window: presented", presented, "frames")
}
