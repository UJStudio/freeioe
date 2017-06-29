local skynet = require 'skynet'
local snax = require 'skynet.snax'
local mosq = require 'mosquitto'
local log = require 'utils.log'
local coroutine = require 'skynet.coroutine'
local datacenter = require 'skynet.datacenter'

local mqtt_id = "UNKNOWN.CLLIENT.ID"
local mqtt_host = "cloud.symgrid.cn"
local mqtt_port = 1883
local mqtt_keepalive = 300
local mqtt_timeout = 1 -- 1 seconds
local mqtt_client = nil

local enable_async = true
local enable_data_upload = true

local topics = {
	"app",
	"sys",
	"data",
	"comm",
}

local wildtopics = {
	"app/+",
	"sys/+",
	"data/+",
	"comm/+",
}

local log_func = nil
local null_log_print = function() end
local log_callback = function(level, ...)
	if not log_func then
		log_func = {}
		log_func[mosq.LOG_NONE] = log.trace
		log_func[mosq.LOG_INFO] = log.info
		log_func[mosq.LOG_NOTICE] = log.notice
		log_func[mosq.LOG_WARNING] = log.warning
		log_func[mosq.LOG_ERROR] = log.error
		log_func[mosq.LOG_DEBUG] = null_log_print
		--log_func[mosq.LOG_DEBUG] = log.debug
	end

	local func = log_func[level] or print
	func(...)
end

local msg_callback = function(packet_id, topic, data, qos, retained)
	log.debug("msg_callback", packet_id, topic, data, qos, retained)
end

local function load_conf()
	mqtt_id = datacenter.get("CLOUD", "ID") or mqtt_id
	mqtt_host = datacenter.get("CLOUD", "HOST") or mqtt_host
	mqtt_port = datacenter.get("CLOUD", "PORT") or mqtt_port
	mqtt_timeout = datacenter.get("CLOUD", "TIMEOUT") or mqtt_timeout
end

function response.ping()
	if mqtt_client then
		mqtt_client:publish(mqtt_id.."/app", "ping........", 1, true)
	end
	return "PONG"
end

function response.connect(clean_session, username, password)
	local clean_session = clean_session or true
	local client = mosq.new(mqtt_id, clean_session)
	if username then
		client:login_set(username, password)
	end
	client.ON_CONNECT = function(success, rc, msg) 
		if success then
			log.notice("ON_CONNECT", success, rc, msg) 
			mqtt_client = client
			for _, v in ipairs(topics) do
				local pid = client:subscribe(mqtt_id.."/"..v, 1)
			end
			for _, v in ipairs(wildtopics) do
				local pid = client:subscribe(mqtt_id.."/"..v, 1)
			end
		end
	end
	client.ON_DISCONNECT = function(success, rc, msg) 
		log.warning("ON_DISCONNECT", success, rc, msg) 
	end

	--[[
	client.ON_PUBLISH = function(...) log.debug("ON_PUBLISH", ...) end
	client.ON_SUBSCRIBE = function(...) log.debug("ON_SUBSCRIBE", ...) end
	client.ON_UNSUBSCRIBE = function(...) log.debug("ON_UNSUBSCRIBE", ...) end
	--client.ON_LOG = function(...) log.debug("ON_LOG", ...) end
	]]--

	client.ON_LOG = log_callback
	client.ON_MESSAGE = msg_callback

	if enable_async then
		local r, err = client:connect_async(mqtt_host, mqtt_port, mqtt_keepalive)
		client:loop_start()

		-- If we do not sleep, we will got crash :-(
		skynet.sleep(10)
	else
		local r, err = client:connect(mqtt_host, mqtt_port, mqtt_keepalive)
		mqtt_client = client

		skynet.fork(function()
			while mqtt_client do
				mqtt_client:loop(50, 1)
				skynet.sleep(0)
			end
		end)
	end

	return true
end

function response.disconnect()
	local client = mqtt_client
	log.debug("Cloud Connection Closing!")

	--[[
	for _, v in ipairs(topics) do
	client:unsubscribe(mqtt_id.."/"..v)
	end
	for _, v in ipairs(wildtopics) do
	client:unsubscribe(mqtt_id.."/"..v)
	end

	skynet.sleep(100)
	]]--

	mqtt_client = nil
	client:disconnect()
	if enable_async then
		client:loop_stop()
	end
	client:destroy()

	log.notice("Cloud Connection Closed!")
	return true
end

function accept.enable_log(enable)
	local logger = snax.uniqueservice('logger')
	local obj = snax.self()
	if enable then
		logger.post.reg_snax(obj.handle, obj.type)
	else
		logger.post.unreg_snax(obj.handle)
	end
end

function accept.enable_data_upload(enable)
	enable_data_upload = enable
end

function accept.log(lvl, ...)
	if mqtt_client then
		mqtt_client:publish(mqtt_id.."/log/"..lvl, table.concat({...}, '\t'), 1, false)
	end
end

function init()
	load_conf()
	log.debug("MQTT:", mqtt_id, mqtt_host, mqtt_port, mqtt_timeout)

	mosq.init()
end

function exit(...)
	mosq.cleanup()
end
