#!/usr/bin/env luajit
local ffi = require 'ffi'
local assert = require 'ext.assert'
local range = require 'ext.range'
local Threads = require 'pureffi.threads'
local App = require 'glapp':subclass()
local gl = require 'gl'
local getTime = require 'ext.timer'.getTime
local GLTex2D = require 'gl.tex2d'
local GLSceneObject = require 'gl.sceneobject'
App.title = 'MoldWars'

local numint32perintptr = math.max(1, ffi.sizeof'intptr_t' / ffi.sizeof'int32_t')
local texDataSep = ffi.new('uint32_t[?]', numint32perintptr)
assert.eq(numint32perintptr, 2)	-- i'mma hardcode this into worker so I dont have any scope access outside worker

local worker = function(w)
	local startRow = w.startRow
	local endRow = w.endRow
	local texWidth = w.texWidth
	local texHeight = w.texHeight

	local ffi = require 'ffi'
	local texDataIntPtr = bit.bor(
		ffi.cast('intptr_t', w[0]),
		bit.lshift(ffi.cast('intptr_t', w[1]), 32)
	)
	local texData = ffi.cast('uint32_t*', texDataIntPtr)

	local len = texWidth * texHeight
	for y=startRow,endRow-1 do
		for x=0,texWidth do
			local i = x + texWidth * y
			local di = math.random(0,3)
			di = (bit.band(di, 2) - 1) * (bit.band(di, 1) * (texWidth - 1) + 1)
			local src = texData[(i + di) % len]
			local r = bit.band((src + math.random(0,2) - 1), 0xff)
			local g = bit.band((src + bit.lshift((math.random(0,2)-1), 8)), 0xff00)
			local b = bit.band((src + bit.lshift((math.random(0,2)-1), 16)), 0xff0000)
			texData[i] = bit.bor(r, g, b)
		end
	end

	return true
end

local numThreads = Threads.get_thread_count()
local threads = Threads.new_pool(worker, numThreads)

-- tex and update size:
local texWidth, texHeight = 256, 256
App.width = texWidth * 3
App.height = texHeight * 3

function App:initGL()
	local len = texWidth * texHeight
	self.texData = ffi.new('uint32_t[?]', len)
	for i=0,len-1 do
		self.texData[i] = math.random(0, 0xffffffff)
	end
	self.tex = GLTex2D{
		width = texWidth,
		height = texHeight,
		internalFormat = gl.GL_RGBA,
		magFilter = gl.GL_NEAREST,
		minFilter = gl.GL_NEAREST,
		data = self.texData,
	}
	self.sceneObj = GLSceneObject{
		program = {
			version = 'latest',
			precision = 'best',
			vertexCode = [[
in vec2 vertex;
out vec2 tcv;
void main() {
	gl_Position = vec4(vertex * 2. - 1., 0., 1.);
	tcv = vertex;
}
]],
			fragmentCode = [[
uniform sampler2D tex;
in vec2 tcv;
out vec4 fragColor;
void main() {
	fragColor = texture(tex, tcv);
}
]],
			uniforms = {
				tex = 0,
			},
		},
		vertexes = {
			data = {
				0, 0,
				1, 0,
				0, 1,
				1, 1,
			},
			dim = 2,
		},
		geometry = {
			mode = gl.GL_TRIANGLE_STRIP,
		},
	}
	self.sceneObj.program:use()
	self.sceneObj.vao:bind()
end

local lastTime = getTime()
local fpsFrames = 0
local fpsSeconds = 0
local drawsPerSecond = 0

--[[
while-loop counting 28mil fps cycles/second on a 2.9 GHz means 103 cycles per frame, i.e. frame update takes 3.5e-8 seconds
empty App.update loop is 13k fps, i.e. 223077 cycles, i.e. frame update takes 7.7e-5 seconds
App.update + draw without texData-update: 1450 fps, 2000000 cycles, i.e. frame update takes 5e-7 seconds
App.update + texData-update without draw: 300 fps, 9666667 cycles, i.e. frame update takes 0.003 seconds
with subimage and draw, 250 fps, i.e. 11600000 cycles, i.e. frame update takes 0.004 seconds
--]]
--while true do
function App:update()
	local thisTime = getTime()
	local deltaTime = thisTime - lastTime
	fpsFrames = fpsFrames + 1
	fpsSeconds = fpsSeconds + deltaTime
	if fpsSeconds > 1 then
		print('FPS: '..(fpsFrames / fpsSeconds))
		drawsPerSecond = 0
		fpsFrames = 0
		fpsSeconds = 0
	end
	lastTime = thisTime
	
	ffi.cast('intptr_t*', texDataSep)[0] = ffi.cast('intptr_t', ffi.cast('void*', self.texData))
	threads:submit_all(range(numThreads):mapi(function(i)
		local w = {
			startRow = math.floor((i-1) / numThreads * texHeight),	-- inclusive
			endRow = math.floor(i / numThreads * texHeight),		-- exclusive
			texWidth = texWidth,
			texHeight = texHeight,
			--texData = ffi.cast('uint32_t*', self.texData),
		}
		for i=0,numint32perintptr-1 do
			w[i] = texDataSep[i]
		end
		return w
	end))
	threads:wait_all()

	self.tex:subimage()
	self.sceneObj.geometry:draw()
end
App():run()
threads:shutdown()
