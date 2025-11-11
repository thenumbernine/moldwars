#!/usr/bin/env luajit
local ffi = require 'ffi'
local template = require 'template'
local assert = require 'ext.assert'
local range = require 'ext.range'
local Threads = require 'pureffi.threads'
local App = require 'glapp':subclass()
local gl = require 'gl'
local getTime = require 'ext.timer'.getTime
local GLTex2D = require 'gl.tex2d'
local GLSceneObject = require 'gl.sceneobject'
App.title = 'MoldWars'

-- tex and update size:
local texWidth, texHeight = 256, 256
local texelCount = texWidth * texHeight
texData = ffi.new('uint32_t[?]', texelCount)

local worker = load(template([[
local ffi = require 'ffi'
local texWidth, texHeight = <?=texWidth?>, <?=texHeight?>
local texData = ffi.cast('uint32_t*', <?=texData?>)
local w = ...
	local startRow = w.startRow
	local endRow = w.endRow

	local workSize = (endRow - startRow) * texWidth
	local threadOffset = startRow * texWidth
	for localIndex = 0,workSize-1 do
		local i = localIndex + threadOffset
		local di = math.random(0,3)
		di = (bit.band(di, 2) - 1) * (bit.band(di, 1) * (texWidth - 1) + 1)
		local src = texData[(i + di) % <?=texelCount?>]
		local r = bit.band((src + math.random(0,2) - 1), 0xff)
		local g = bit.band((src + bit.lshift((math.random(0,2)-1), 8)), 0xff00)
		local b = bit.band((src + bit.lshift((math.random(0,2)-1), 16)), 0xff0000)
		texData[i] = bit.bor(r, g, b)
	end

	return true
]], {
	texWidth = texWidth,
	texHeight = texHeight,
	texelCount = texelCount,
	texData = tostring(ffi.cast('uintptr_t', ffi.cast('void*', texData))), 
}))

local numThreads = Threads.get_thread_count()
local threads = Threads.new_pool(worker, numThreads)

App.width = texWidth * 3
App.height = texHeight * 3

function App:initGL()
	for i=0,texelCount-1 do
		texData[i] = math.random(0, 0xffffffff)
	end
	self.tex = GLTex2D{
		width = texWidth,
		height = texHeight,
		internalFormat = gl.GL_RGBA,
		magFilter = gl.GL_NEAREST,
		minFilter = gl.GL_NEAREST,
		data = texData,
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
	
	threads:submit_all(range(numThreads):mapi(function(i)
		return {
			startRow = math.floor((i-1) / numThreads * texHeight),	-- inclusive
			endRow = math.floor(i / numThreads * texHeight),		-- exclusive
		}
	end))
	threads:wait_all()

	self.tex:subimage()
	self.sceneObj.geometry:draw()
end
App():run()
threads:shutdown()
