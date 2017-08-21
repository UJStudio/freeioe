local class = require 'middleclass'
local socket = require 'skynet.socket'
local modbus = require 'modbus.init'
local sm_client = require 'modbus.skynet_client'
local socketchannel = require 'socketchannel'
local serialchannel = require 'serialchannel'

local app = class("XXXX_App")

function app:initialize(name, conf, sys)
	self._name = name
	self._conf = conf
	self._sys = sys
	self._api = sys:data_api()
	self._log = sys:logger()
	self._log:debug(name.." Application initlized")
end

function app:start()
	self._api:set_handler({
		on_ctrl = function(...)
			print(...)
		end,
	})

	local sys_id = self._sys:id()
	local config = self._conf or {
		channel_type = 'socket'
	}

	local inputs = {}
	for i = 1, 10 do
		inputs[#inputs + 1] = { 
			name='tag'..i,
			desc='tag'..i..' description',
		}
	end

	local dev_sn = sys_id..".modbus_"..self._name
	local dev = self._api:add_device(dev_sn, inputs)
	local client = nil

	if config.channel_type == 'socket' then
		opt = {
			host = "127.0.0.1",
			port = 1502,
			nodelay = true,
		}
		print('socket')
		client = sm_client(socketchannel, opt, modbus.apdu_tcp, i)
	else
		opt = {
			port = "/dev/ttymxc1",
			baudrate = 115200
		}
		print('serial')
		client = sm_client(serialchannel, opt, modbus.apdu_rtu, i)
	end
	client:set_io_cb(function(io, msg)
		dev:dump_comm(io, msg)
	end)
	self._client1 = client

	return true
end

function app:close(reason)
	print(self._name, reason)
end

function decode_registers(raw, count)
	local d = modbus.decode
	local len = d.uint8(raw, 2)
	assert(len >= count * 2)
	local regs = {}
	for i = 0, count - 1 do
		regs[#regs + 1] = d.uint16(raw, i * 2 + 3)
	end
	return regs
end

function app:run(tms)
	local client = self._client1
	if not client then
		return
	end

	local base_address = 0x00
	local req = {
		func = 0x03,
		addr = base_address,
		len = 10,
	}
	local r, pdu, err = pcall(function(req, timeout) 
		print('call request')
		return client:request(req, timeout)
	end, req, 1000)

	if not r then 
		pdu = tostring(pdu)
		if string.find(pdu, 'timeout') then
			self._log:debug(pdu, err)
		else
			self._log:error(pdu, err)
		end
		return
	end

	if not pdu then 
		self._log:error("read failed: " .. err) 
		return
	end

	local regs = decode_registers(raw, 10)
	local now = self._sys:time()

	for r,v in ipairs(regs) do
		self._dev1:set_input_prop('tag'..r, "value", math.tointeger(v), now, 0)
	end

	return tms
end

return app
