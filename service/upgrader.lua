local lfs = require 'lfs'
local skynet = require 'skynet.manager'
local snax = require 'skynet.snax'
local datacenter = require 'skynet.datacenter'
--local queue = require 'skynet.queue'
local lockable_queue = require 'skynet.lockable_queue'
local log = require 'utils.logger'.new('UPGRADER')
local sysinfo = require 'utils.sysinfo'
local ioe = require 'ioe'
local pkg = require 'pkg'
local pkg_api = require 'pkg.api'

local sys_lock = nil
local app_lock = nil
--local task_lock = nil
local tasks = {}
local aborting = false

local command = {}

local get_target_folder = pkg.get_app_folder
local parse_version_string = pkg.parse_version_string
local get_app_version = pkg.get_app_version

local function get_ioe_dir()
	return os.getenv('IOE_DIR') or lfs.currentdir().."/.."
end

local reserved_list = {
	"ioe", "ioe_frpc", "ioe_symlink",
	"UBUS", "CLOUD", "AppMgr", "CFG", "LWF", "EXT",
	"RunBatch", "BUFFER", "UPGRADER"
}

local function is_inst_name_reserved(inst)
	for _, v in ipairs(reserved_list) do
		if v == inst then
			return true
		end
	end
end

local function action_result(channel, id, result, info, ...)
	local info = info or (result and 'Done [UNKNOWN]' or 'Error! [UNKNOWN]')
	if result then
		log.info(info, ...)
	else
		log.error(info, ...)
	end

	if id and id ~= 'from_web' then
		local cloud = snax.queryservice('cloud')
		cloud.post.action_result(channel, id, result, info, ...)
	end
	return result, ...
end

local function fire_warning_event(info, data)
	local appmgr = snax.queryservice("appmgr")
	local event = require 'app.event'
	appmgr.post.fire_event('ioe', ioe.id(), event.LEVEL_WARNING, event.EVENT_SYS, info, data)
end

--[[
local function xpcall_ret(channel, id, ok, ...)
	if ok then
		return action_result(channel, id, ...)
	end
	return action_result(channel, id, false, ...)
end

local function action_exec(channel, func)
	local channel = channel
	local func = func
	return function(id, args)
		return xpcall_ret(channel, id, xpcall(func, debug.traceback, id, args))
	end
end
]]--

--[[
local function create_task(lock, task_func)
	local spawn_co = {}
	skynet.fork(function()
		-- Make sure we locked the queue
		skynet.wakeup(spawn_co)
		task_lock(task_func)
	end)
	skynet.wait(spawn_co)
	return true
end
]]--

local function create_task(func, task_name, ...)
	skynet.fork(function(task_name, ...)
		local co = coroutine.running()
		tasks[co] = {
			name = task_name
		}
		local r, err = func(...)
		tasks[co] = nil

		if not r then
			log.error("Task executed failed.", task_name, err)
		end
	end, task_name, ...)

	return true, task_name.. " started"
end

local function gen_app_sn(inst_name)
	local cloud = snax.queryservice('cloud')
	return cloud.req.gen_sn(inst_name)
end

local function create_download(channel)
	return function(app, version, success_cb, ext, token, is_core)
		local down = pkg_api.create_download_func(app, version, ext or '.zip', false, token, is_core)
		return down(success_cb)
	end
end

local create_app_download = create_download('app')
local create_sys_download = create_download('sys')

local function map_app_action(func_name, lock)
	local func = command[func_name]
	assert(func)
	local wfunc = function(...)
		local results = {pcall(func, ...)}
		if results[1] then
			return table.unpack(results, 2)
		else
			return table.unpack(results)
		end
	end
	command[func_name] = function(id, args)
		return create_task(function()
			if aborting then
				return action_result('app', id, false, "System is aborting before call ", func_name)
			end
			if ioe.mode() ~= 0 then
				return action_result('app', id, false, 'System mode is locked to '..ioe.mode())
			end
			return action_result('app', id, app_lock(wfunc, lock, id, args))
		end, 'Application Action '..func_name)
	end
end

local function map_sys_action(func_name, lock)
	local func = command[func_name]
	assert(func)
	local wfunc = function(...)
		local results = {pcall(func, ...)}
		if results[1] then
			return table.unpack(results, 2)
		else
			return table.unpack(results)
		end
	end
	command[func_name] = function(id, args)
		return create_task(function()
			if aborting then
				return action_result('sys', id, false, "System is aborting before call ", func_name)
			end
			if ioe.mode() ~= 0 then
				return action_result('sys', id, false, 'System mode is locked to '..ioe.mode())
			end
			return action_result('sys', id, sys_lock(wfunc, lock, id, args))
		end, 'System Action '..func_name)
	end
end

function command.upgrade_app(id, args)
	local inst_name = args.inst
	local version, beta, editor = parse_version_string(args.version)
	if beta and not ioe.beta() then
		return false, "Device is not in beta mode! Cannot install beta version"
	end
	if not pkg.valid_inst(inst_name) then
		return false, "Application instance name invalid!!"
	end

	local app = datacenter.get("APPS", inst_name)
	if not app then
		return false, "There is no app for instance name "..inst_name
	end

	local name = args.fork and args.name or app.name
	if args.name and args.name ~= name then
		return false, "Cannot upgrade application as name is different, installed "..app.name.." wanted "..args.name
	end
	local sn = args.sn or app.sn
	local conf = args.conf or app.conf
	local auto = args.auto ~= nil and args.auto or app.auto
	local token = args.token or app.token

	local download_version = editor and version..".editor" or version
	return create_app_download(name, download_version, function(path)
		log.notice("Download application finished", name)
		local appmgr = snax.queryservice("appmgr")
		local r, err = appmgr.req.stop(inst_name, "Upgrade Application")
		if not r then
			return false, "Failed to stop App. Error: "..err
		end

		local target_folder = get_target_folder(inst_name)
		os.execute("unzip -oq "..path.." -d "..target_folder)
		os.execute("rm -rf "..path)

		if not version or version == 'latest' then
			version = get_app_version(inst_name)
		end
		datacenter.set("APPS", inst_name, {name=name, version=version, sn=sn, conf=conf, token=token, auto=auto})
		if editor then
			datacenter.set("APPS", inst_name, "islocal", 1)
		end

		local r, err = appmgr.req.start(inst_name, conf)
		if r then
			--- Post to appmgr for instance added
			appmgr.post.app_event('upgrade', inst_name)

			return true, "Application upgradation is done!"
		else
			-- Upgrade will not remove app folder
			--datacenter.set("APPS", inst_name, nil)
			--os.execute("rm -rf "..target_folder)
			return false, "Failed to start App. Error: "..err
		end
	end, args.file_ext or '.zip', args.token)
end

function command.install_app(id, args)
	local name = args.name
	local inst_name = args.inst
	local from_web = args.from_web
	local token = args.token
	local version, beta, editor = parse_version_string(args.version)
	if beta and not ioe.beta() then
		return false, "Device is not in beta mode! Cannot install beta version"
	end
	if not pkg.valid_inst(inst_name) then
		return false, "Application instance name invalid!!"
	end

	local sn = args.sn or gen_app_sn(inst_name)
	local conf = args.conf or {}
	if not from_web and is_inst_name_reserved(inst_name) then
		local err = "Application instance name is reserved"
		return false, "Failed to install App. Error: "..err
	end
	if datacenter.get("APPS", inst_name) and not args.force then
		local err = "Application already installed"
		return false, "Failed to install App. Error: "..err
	end

	-- Reserve app instance name
	datacenter.set("APPS", inst_name, {name=name, version=version, sn=sn, token=token, conf=conf, downloading=true, auto=1})

	local download_version = editor and version..".editor" or version
	local r, err = create_app_download(name, download_version, function(info)
		log.notice("Download application finished", name)
		local target_folder = get_target_folder(inst_name)
		lfs.mkdir(target_folder)
		os.execute("unzip -oq "..info.." -d "..target_folder)
		os.execute("rm -rf "..info)

		if not version or version == 'latest' then
			version = get_app_version(inst_name)
		end
		datacenter.set("APPS", inst_name, {name=name, version=version, sn=sn, token=token, conf=conf, auto=1})
		if editor then
			datacenter.set("APPS", inst_name, "islocal", 1)
		end

		local appmgr = snax.queryservice("appmgr")
		local r, err = appmgr.req.start(inst_name, conf)
		if r then
			--- Post to appmgr for instance added
			appmgr.post.app_event('install', inst_name)

			return true, "Application installtion is done"
		else
			-- Keep the application there.
			-- datacenter.set("APPS", inst_name, nil)
			-- os.execute("rm -rf "..target_folder)
			--
			datacenter.set("APPS", inst_name, 'auto', 0)

			appmgr.post.app_event('install', inst_name)

			return false, "Failed to start App. Error: "..err
		end
	end, args.file_ext or '.zip', token)

	return r, err
end

function command.create_app(id, args)
	local name = args.name
	local inst_name = args.inst
	local version = 0

	if not ioe.beta() then
		return false, "Device is not in beta mode! Cannot install beta version"
	end
	if not pkg.valid_inst(inst_name) then
		return false, "Application instance name invalid!!"
	end

	local sn = args.sn or gen_app_sn(inst_name)
	local conf = args.conf or {}
	if is_inst_name_reserved(inst_name) then
		local err = "Application instance name is reserved"
		return false, "Failed to install App. Error: "..err
	end
	if datacenter.get("APPS", inst_name) and not args.force then
		local err = "Application already installed"
		return false, "Failed to install App. Error: "..err
	end

	-- Reserve app instance name
	datacenter.set("APPS", inst_name, {name=name, version=version, sn=sn, conf=conf, islocal=1, auto=0})

	local target_folder = get_target_folder(inst_name)
	lfs.mkdir(target_folder)
	local target_folder_escape = string.gsub(target_folder, ' ', '\\ ')
	os.execute('cp ./ioe/doc/app/example_app.lua '..target_folder_escape..'/app.lua')
	os.execute('echo 0 > '..target_folder.."/version")
	os.execute('echo editor >> '..target_folder.."/version")

	--- Post to appmgr for instance added
	local appmgr = snax.queryservice("appmgr")
	appmgr.post.app_event('create', inst_name)

	return true, "Create application is done!"
end

function command.install_local_app(id, args)
	local name = args.name
	local inst_name = args.inst
	local sn = args.sn or gen_app_sn(inst_name)
	local conf = args.conf or {}
	local file_path = args.file

	if not ioe.beta() then
		return nil, "Device is not in beta mode! Cannot install beta version"
	end
	if not pkg.valid_inst(inst_name) then
		return false, "Application instance name invalid!!"
	end

	if is_inst_name_reserved(inst_name) then
		return false, "Application instance name is reserved"
	end
	if datacenter.get("APPS", inst_name) and not args.force then
		return nil, "Application already installed"
	end

	-- Reserve app instance name
	datacenter.set("APPS", inst_name, {name=name, version=0, sn=sn, conf=conf, islocal=1, auto=0})
	log.notice("Install local application package", file_path)

	local target_folder = get_target_folder(inst_name)
	os.execute("unzip -oq "..file_path.." -d "..target_folder)
	os.execute("rm -rf "..file_path)

	local version = get_app_version(inst_name)
	datacenter.set("APPS", inst_name, "version", version)
	--datacenter.set("APPS", inst_name, "auto", 1)

	--- Post to appmgr for instance added
	local appmgr = snax.queryservice("appmgr")
	appmgr.post.app_event('create', inst_name)

	--[[
	log.notice("Try to start application", inst_name)
	appmgr.post.app_start(inst_name)
	]]--

	return true, "Install location application done!"
end

function command.rename_app(id, args)
	local inst_name = args.inst
	local new_name = args.new_name
	if not pkg.valid_inst(inst_name) or not pkg.valid_inst(new_name) then
		return false, "Application instance name invalid!!"
	end
	if is_inst_name_reserved(inst_name) then
		return nil, "Application instance name is reserved"
	end
	if is_inst_name_reserved(new_name) then
		return nil, "Application new name is reserved"
	end
	if datacenter.get("APPS", new_name) and not args.force then
		return nil, "Application new already used"
	end
	local app = datacenter.get("APPS", inst_name)
	if not app then
		return nil, "Application instance not installed"
	end
	local appmgr = snax.queryservice("appmgr")
	appmgr.req.stop(inst_name, "Renaming application")
	app.sn = args.sn or gen_app_sn(new_name)

	local source_folder = get_target_folder(inst_name)
	local target_folder = get_target_folder(new_name)
	os.execute("mv "..source_folder.." "..target_folder)

	datacenter.set("APPS", inst_name, nil)
	datacenter.set("APPS", new_name, app)

	--- rename event will start the application
	appmgr.post.app_event('rename', inst_name, new_name)

	return true, "Rename application is done!"
end

function command.install_missing_app(inst_name)
	skynet.timeout(500, function()
		local info = datacenter.get("APPS", inst_name)
		if not info or info.islocal then
			return
		end
		return command.install_app(nil, {
			inst = inst_name,
			name = info.name,
			version = info.version,
			token = info.token,
			sn = info.sn,
			conf = info.conf,
			force = true
		})
	end)
	return true, "Install missing application "..inst_name.." done!"
end

function command.uninstall_app(id, args)
	local inst_name = args.inst
	if not pkg.valid_inst(inst_name) then
		return false, "Application instance name invalid!!"
	end

	local appmgr = snax.queryservice("appmgr")
	local target_folder = get_target_folder(inst_name)

	local r, err = appmgr.req.stop(inst_name, "Uninstall App")
	if r then
		os.execute("rm -rf "..target_folder)
		datacenter.set("APPS", inst_name, nil)
		appmgr.post.app_event('uninstall', inst_name)
		return true, "Application uninstall is done"
	else
		return false, "Application uninstall failed, Error: "..err
	end
end

function command.list_app()
	return datacenter.get("APPS")
end

function command.latest_version(app, is_core)
	local r, err = pkg_api.latest_version(app, is_core)
	if not r then
		log.error(err, app, is_core)
		r = { version = 0, beta = true }
	else
		log.info("Got app latest version", r.version, r.beta, app, is_core)
	end
	return r
end

function command.check_version(app, version, is_core)
	local r, err = pkg_api.check_version(app, version, is_core)
	if r == nil then
		log.error(err, app, is_core)
		r = true
	else
		log.info("Got app version", r, app, is_core)
	end
	return r
end

function command.enable_beta()
	local fn = get_ioe_dir()..'/ipt/using_beta'

	if lfs.attributes(fn, 'mode') then
		return true
	end

	os.execute('date > '..fn)
	return true
end

function command.user_access(auth_code)
	return pkg_api.user_access(auth_code)
end

local function download_upgrade_skynet(id, args, cb)
	local skynet_version = args
	if type(args) == 'table' then
		skynet_version = args.version
	end

	--local is_windows = package.config:sub(1,1) == '\\'
	local version, beta = parse_version_string(skynet_version)
	return create_sys_download('skynet', version, cb, ".tar.gz", args.token, true)
end

--[[
local function get_ps_e()
	local r, status, code = os.execute("ps -e > /dev/null")
	if not r then
		return "ps"
	end
	return "ps -e"
end
]]--

local upgrade_sh_str = [[
#!/bin/sh

IOE_DIR=%s
SKYNET_FILE=%s
SKYNET_PATH=%s
FREEIOE_FILE=%s
FREEIOE_PATH=%s

date > $IOE_DIR/ipt/rollback
cp -f $SKYNET_PATH/cfg.json $IOE_DIR/ipt/cfg.json.bak
cp -f $SKYNET_PATH/cfg.json.md5 $IOE_DIR/ipt/cfg.json.md5.bak

cd $IOE_DIR
if [ -f $SKYNET_FILE ]
then
	cd $SKYNET_PATH
	rm ./lualib -rf
	rm ./luaclib -rf
	rm ./service -rf
	rm ./cservice -rf
	tar xzf $SKYNET_FILE

	if [ $? -eq 0 ]
	then
		echo "Skynet upgrade is done!"
	else
		echo "Skynet uncompress error!! Rollback..."
		rm -f $SKYNET_FILE
		sh $IOE_DIR/ipt/rollback.sh
		exit $?
	fi
fi

cd "$IOE_DIR"
if [ -f $FREEIOE_FILE ]
then
	cd $FREEIOE_PATH
	rm ./www -rf
	rm ./lualib -rf
	rm ./snax -rf
	rm ./test -rf
	rm ./service -rf
	rm ./ext -rf
	tar xzf $FREEIOE_FILE

	if [ $? -eq 0 ]
	then
		echo "FreeIOE upgrade is done!"
	else
		echo "FreeIOE uncompress error!! Rollback..."
		rm -f $FREEIOE_FILE
		sh $IOE_DIR/ipt/rollback.sh
		exit $?
	fi
fi

if [ -f $IOE_DIR/ipt/strip_mode ]
then
	rm -f $IOE_DIR/ipt/rollback
	rm -f $IOE_DIR/ipt/upgrade_no_ack

	if [ -f $IOE_DIR/ipt/rollback.sh.new ]
	then
		mv -f $IOE_DIR/ipt/rollback.sh.new $IOE_DIR/ipt/rollback.sh
	fi

	[ -f $SKYNET_FILE ] && rm -f $SKYNET_FILE
	[ -f $FREEIOE_FILE ] && rm -f $FREEIOE_FILE

	exit 0
fi

if [ -f $IOE_DIR/ipt/upgrade_no_ack ]
then
	rm -f $IOE_DIR/ipt/rollback
	rm -f $IOE_DIR/ipt/upgrade_no_ack

	if [ -f $IOE_DIR/ipt/rollback.sh.new ]
	then
		mv -f $IOE_DIR/ipt/rollback.sh.new $IOE_DIR/ipt/rollback.sh
	fi

	if [ -f $SKYNET_FILE ]
	then
		mv -f $SKYNET_FILE $IOE_DIR/ipt/skynet.tar.gz
	fi
	if [ -f $FREEIOE_FILE ]
	then
		mv -f $FREEIOE_FILE $IOE_DIR/ipt/freeioe.tar.gz
	fi
else
	if [ -f $SKYNET_FILE ]
	then
		mv -f $SKYNET_FILE $IOE_DIR/ipt/skynet.tar.gz.new
	fi
	if [ -f $FREEIOE_FILE ]
	then
		mv -f $FREEIOE_FILE $IOE_DIR/ipt/freeioe.tar.gz.new
	fi
fi

sync

]]

local rollback_sh_str = [[
#!/bin/sh

IOE_DIR=%s
SKYNET_PATH=%s
FREEIOE_PATH=%s

if [ -f $IOE_DIR/ipt/skynet.tar.gz ]
then
	cd $IOE_DIR
	cd $SKYNET_PATH
	tar xzf $IOE_DIR/ipt/skynet.tar.gz
fi

if [ -f $IOE_DIR/ipt/freeioe.tar.gz ]
then
	cd $IOE_DIR
	cd $FREEIOE_PATH
	tar xzf $IOE_DIR/ipt/freeioe.tar.gz
fi

if [ -f $IOE_DIR/ipt/cfg.json.bak ]
then
	cp -f $IOE_DIR/ipt/cfg.json.bak $SKYNET_PATH/cfg.json
	cp -f $IOE_DIR/ipt/cfg.json.md5.bak $SKYNET_PATH/cfg.json.md5
fi

sync
]]

local upgrade_ack_sh_str = [[
#!/bin/sh

IOE_DIR=%s

if [ -f $IOE_DIR/ipt/skynet.tar.gz.new ]
then
	mv -f $IOE_DIR/ipt/skynet.tar.gz.new $IOE_DIR/ipt/skynet.tar.gz
fi

if [ -f $IOE_DIR/ipt/freeioe.tar.gz.new ]
then
	mv -f $IOE_DIR/ipt/freeioe.tar.gz.new $IOE_DIR/ipt/freeioe.tar.gz
fi

if [ -f $IOE_DIR/ipt/rollback.sh.new ]
then
	mv -f $IOE_DIR/ipt/rollback.sh.new $IOE_DIR/ipt/rollback.sh
fi

rm -f $IOE_DIR/ipt/rollback

sync

]]

local function write_script(fn, str)
	local f, err = io.open(fn, "w+")
	if not f then
		return nil, err
	end
	f:write(str)
	f:close()
	return true
end

local function start_upgrade_proc(ioe_path, skynet_path)
	assert(ioe_path or skynet_path)
	local ioe_path = ioe_path or '/IamNotExits.unknown'
	local skynet_path = skynet_path or '/IamNotExits.unknown'
	log.warning("Core system upgradation starting....")
	log.trace(ioe_path, skynet_path)
	--local ps_e = get_ps_e()

	local base_dir = get_ioe_dir()

	local str = string.format(rollback_sh_str, base_dir, "skynet", "freeioe")
	local r, err = write_script(base_dir.."/ipt/rollback.sh.new", str)
	if not r then
		return false, err
	end

	local str = string.format(upgrade_ack_sh_str, base_dir)
	local r, err = write_script(base_dir.."/ipt/upgrade_ack.sh", str)
	if not r then
		return false, err
	end

	local str = string.format(upgrade_sh_str, base_dir, skynet_path, "skynet", ioe_path, "freeioe")
	local r, err = write_script(base_dir.."/ipt/upgrade.sh", str)
	if not r then
		return false, err
	end
	write_script(base_dir.."/ipt/upgrade", os.date())

	-- Call system abort
	ioe.abort()
	-- mark the aborting after call abort
	aborting = true
	log.warning("Core system upgradation done!")
	return true, "System upgradation is done!"
end

function command.upgrade_core(id, args)
	--local is_windows = package.config:sub(1,1) == '\\'

	if args.no_ack then
		local base_dir = get_ioe_dir()
		local r, status, code = os.execute("date > "..base_dir.."/ipt/upgrade_no_ack")
		if not r then
			log.error("Create upgrade_no_ack failed", status, code)
			return false, "Failed to create upgrade_no_ack file!"
		end
	end


	--- Upgrade skynet only
	if not args.version or tonumber(args.version) <= 0 or string.lower(args.version) == 'none' then
		return download_upgrade_skynet(id, args.skynet, function(path)
			return start_upgrade_proc(nil, path)
		end)
	end

	-- Upgrade both
	local version, beta = parse_version_string(args.version)
	local skynet_version = type(args.skynet) == 'table' and args.skynet.version or args.skynet

	return create_sys_download('freeioe', version, function(path)
		local freeioe_path = path
		if skynet_version then
			return download_upgrade_skynet(id, args.skynet, function(path)
				return start_upgrade_proc(freeioe_path, path)
			end)
		else
			return start_upgrade_proc(freeioe_path)
		end
	end, ".tar.gz", args.token, true)
end

local rollback_time = nil
function command.upgrade_core_ack(id, args)
	local base_dir = get_ioe_dir()
	local upgrade_ack_sh = base_dir.."/ipt/upgrade_ack.sh"
	local r, status, code = os.execute("sh "..upgrade_ack_sh)
	if not r then
		return false, "Failed execute ugprade_ack.sh.  "..status.." "..code
	end
	rollback_time = nil
	return true, "System upgradation ACK is done"
end

function command.rollback_time()
	return rollback_time and math.floor(rollback_time - skynet.time()) or nil
end

function command.is_upgrading()
	-- TODO: make a upgrading flag?
	return false
end

function command.list_tasks()
	return tasks
end

function command.system_reboot(id, args)
	aborting = true
	local delay = args.delay or 5
	ioe.abort_prepare()
	skynet.timeout(delay * 100, function()
		os.execute("reboot &")
	end)
	return true, "Device will reboot after "..delay.." ms"
end

function command.system_quit(id, args)
	aborting = true

	local appmgr = snax.uniqueservice("appmgr")
	if appmgr then
		appmgr.post.close_all("FreeIOE is aborting!!!")
	end

	local delay = args.delay or 5
	skynet.timeout(delay * 100, function()
		skynet.abort()
	end)

	return true, "FreeIOE will reboot after "..delay.." s"
end

local function check_rollback()
	local fn = get_ioe_dir()..'/ipt/rollback'
	if lfs.attributes(fn, 'mode') then
		return true
	end
	return false
end

local function rollback_co()
	log.warning("Rollback will be applied in five minutes")

	local do_rollback = nil
	do_rollback = function()
		local data = { version=sysinfo.version(), skynet_version=sysinfo.skynet_version() }
		fire_warning_event('System will be rollback!', data)
		log.error("System will be rollback!")

		aborting = true
		skynet.sleep(100)
		do_rollback = nil
		ioe.abort()
	end

	rollback_time = skynet.time() + 5 * 60
	skynet.timeout(5 * 60 * 100, function()
		if do_rollback then do_rollback() end
	end)

	while do_rollback do
		skynet.sleep(100)
		if not check_rollback() then do_rollback = nil end
	end
end

-- map action result functions
map_app_action('upgrade_app', false)
map_app_action('install_app', false)
map_app_action('create_app', false)
map_app_action('install_local_app', false)
map_app_action('rename_app', false)
map_app_action('uninstall_app', false)

map_sys_action('upgrade_core', true)
--map_action('upgrade_code_ack', 'sys')
map_sys_action('system_reboot', true)
map_sys_action('system_quit', true)

skynet.start(function()
	sys_lock = lockable_queue()
	app_lock = lockable_queue(sys_lock, false)
	--task_lock = queue()

	lfs.mkdir(get_ioe_dir().."/ipt")

	skynet.dispatch("lua", function(session, address, cmd, ...)
		local f = command[string.lower(cmd)]
		if f then
			skynet.ret(skynet.pack(f(...)))
		else
			error(string.format("Unknown command %s", tostring(cmd)))
		end
	end)

	--- For rollback thread
	if check_rollback() then
		skynet.fork(function()
			sys_lock(rollback_co, true)
		end)
		skynet.sleep(20)
	end

	skynet.register ".upgrader"
end)

