--!A cross-platform build utility based on Lua
--
-- Licensed to the Apache Software Foundation (ASF) under one
-- or more contributor license agreements.  See the NOTICE file
-- distributed with this work for additional information
-- regarding copyright ownership.  The ASF licenses this file
-- to you under the Apache License, Version 2.0 (the
-- "License"); you may not use this file except in compliance
-- with the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
-- 
-- Copyright (C) 2015 - 2019, TBOOX Open Source Group.
--
-- @author      ruki
-- @file        package.lua
--

-- imports
import("core.base.semver")
import("core.base.option")
import("core.base.global")
import("lib.detect.cache", {alias = "detectcache"})
import("core.project.project")
import("core.package.package", {alias = "core_package"})
import("action")
import("devel.git")
import("net.fasturl")
import("repository")

--
-- parse require string
--
-- add_requires("zlib")
-- add_requires("tbox >=1.5.1", "zlib >=1.2.11")
-- add_requires("zlib master")
-- add_requires("xmake-repo@tbox >=1.5.1") 
-- add_requires("aaa_bbb_ccc >=1.5.1 <1.6.0", {optional = true, alias = "mypkg", debug = true})
-- add_requires("tbox", {config = {coroutine = true, abc = "xxx"}})
-- add_requires("xmake::xmake-repo@tbox >=1.5.1") 
-- add_requires("conan::OpenSSL/1.0.2n@conan/stable")
-- add_requires("brew::pcre2/libpcre2-8 10.x", {alias = "pcre2"})
--
-- {system = nil/true/false}:
--   nil: get local or system packages
--   true: only get system package
--   false: only get local packages
--
function _parse_require(require_str, requires_extra, parentinfo)

    -- get it from cache first
    local requires = _g._REQUIRES or {}
    local required = requires[require_str]
    if required then
        return required.packagename, required.requireinfo
    end

    -- split package and version info
    local splitinfo = require_str:split('%s+')
    assert(splitinfo and #splitinfo > 0, "require(\"%s\"): invalid!", require_str)

    -- get package info
    local packageinfo = splitinfo[1]

    -- get version
    --
    -- .e.g 
    -- 
    -- lastest
    -- >=1.5.1 <1.6.0  
    -- master || >1.4
    -- ~1.2.3
    -- ^1.1
    --
    local version = "lastest"
    if #splitinfo > 1 then
        version = table.concat(table.slice(splitinfo, 2), " ")
    end
    assert(version, "require(\"%s\"): unknown version!", require_str)

    -- require third-party packages? e.g. brew::pcre2/libpcre2-8
    local reponame    = nil
    local packagename = nil
    if require_str:find("::", 1, true) then
        packagename = packageinfo
    else

        -- get repository name, package name and package url
        local pos = packageinfo:find_last('@', true)
        if pos then

            -- get package name
            packagename = packageinfo:sub(pos + 1)

            -- get reponame 
            reponame = packageinfo:sub(1, pos - 1)
        else 
            packagename = packageinfo
        end
    end

    -- check package name
    assert(packagename, "require(\"%s\"): the package name not found!", require_str)

    -- get require extra
    local require_extra = {}
    if requires_extra then
        require_extra = requires_extra[require_str] or {}
    end

    -- get required building configurations
    local require_build_configs = require_extra.configs or require_extra.config
    if require_extra.debug then
        require_build_configs = require_build_configs or {}
        require_build_configs.debug = true
    end

    -- init required item
    local required = {}
    parentinfo = parentinfo or {}
    required.packagename = packagename
    required.requireinfo =
    {
        originstr        = require_str,
        reponame         = reponame,
        version          = version,
        alias            = require_extra.alias,     -- set package alias name
        group            = require_extra.group,     -- only uses the first package in same group
        system           = require_extra.system,    -- default: true, we can set it to disable system package manually
        option           = require_extra.option,    -- set and attach option
        configs          = require_build_configs,   -- the required building configurations
        default          = require_extra.default,   -- default: true, we can set it to disable package manually
        optional         = parentinfo.optional or require_extra.optional -- default: false, inherit parentinfo.optional
    }

    -- save this required item to cache
    requires[require_str] = required
    _g._REQUIRES = requires

    -- ok
    return required.packagename, required.requireinfo
end

-- load package package from system
function _load_package_from_system(packagename)
    return core_package.load_from_system(packagename)
end

-- load package package from project
function _load_package_from_project(packagename)
    return core_package.load_from_project(packagename)
end

-- load package package from repositories
function _load_package_from_repository(packagename, reponame)

    -- get package directory from the given package name
    local packagedir, repo = repository.packagedir(packagename, reponame)
    if packagedir then
        -- load it
        return core_package.load_from_repository(packagename, repo, packagedir)
    end
end

-- load required packages
function _load_package(packagename, requireinfo)

    -- attempt to get it from cache first
    local packages = _g._PACKAGES or {}
    local package = packages[packagename]
    if package then

        -- satisfy required version? 
        local version_str = package:version_str()
        if version_str and not semver.satisfies(version_str, requireinfo.version) then
            raise("package(%s): version conflict, '%s' does not satisfy '%s'!", packagename, version_str, requireinfo.version)
        end

        -- ok
        return package
    end

    -- load package from project first
    if os.isfile(os.projectfile()) then
        package = _load_package_from_project(packagename)
    end
        
    -- load package from repositories
    if not package then
        package = _load_package_from_repository(packagename, requireinfo.reponame)
    end

    -- load package from system
    if not package then
        package = _load_package_from_system(packagename)
    end

    -- check
    assert(package, "package(%s) not found!", packagename)

    -- save require info to package
    package:requireinfo_set(requireinfo)

    -- save this package package to cache
    packages[packagename] = package
    _g._PACKAGES = packages

    -- ok
    return package
end

-- search packages from repositories
function _search_packages(name)

    local packages = {}
    for _, packageinfo in ipairs(repository.searchdirs(name)) do
        local package = core_package.load_from_repository(packageinfo.name, packageinfo.repo, packageinfo.packagedir)
        if package then
            table.insert(packages, package)
        end
    end
    return packages
end

-- sort package deps
--
-- .e.g 
--
-- a.deps = b
-- b.deps = c
--
-- orderdeps: c -> b -> a
--
function _sort_packagedeps(package)
    local orderdeps = {}
    for _, dep in pairs(package:deps()) do
        table.join2(orderdeps, _sort_packagedeps(dep))
        table.insert(orderdeps, dep) 
    end
    return orderdeps
end

-- add some builtin configs to package
function _add_package_configs(package)
    package:add("configs", "debug", {builtin = true, description = "Enable debug symbols.", default = false, type = "boolean"})
    package:add("configs", "cflags", {builtin = true, description = "Set the C compiler flags."})
    package:add("configs", "cxflags", {builtin = true, description = "Set the C/C++ compiler flags."})
    package:add("configs", "cxxflags", {builtin = true, description = "Set the C++ compiler flags."})
    package:add("configs", "asflags", {builtin = true, description = "Set the assembler flags."})
    package:add("configs", "vs_runtime", {builtin = true, description = "Set vs compiler runtime.", default = "MT", values = {"MT", "MD"}})
end

-- load all required packages
function _load_packages(requires, opt)

    -- no requires?
    if not requires or #requires == 0 then
        return {}
    end

    -- load packages
    local packages = {}
    for _, requireinfo in ipairs(load_requires(requires, opt.requires_extra, opt.parentinfo)) do

        -- load package 
        local package = _load_package(requireinfo.name, requireinfo.info)

        -- maybe package not found and optional
        if package then

            -- load dependent packages and save them first of this package
            local deps = package:get("deps")
            if deps and opt.nodeps ~= true then
                local packagedeps = {}
                for _, dep in ipairs(_load_packages(deps, {requires_extra = package:get("__extra_deps"), parentinfo = requireinfo.info, nodeps = opt.nodeps})) do
                    table.insert(packages, dep)
                    packagedeps[dep:name()] = dep
                end
                package._DEPS = packagedeps
                package._ORDERDEPS = table.unique(_sort_packagedeps(package))
            end

            -- add some builtin configs to package
            _add_package_configs(package)

            -- save this package package
            table.insert(packages, package)
        end
    end

    -- ok?
    return packages
end

-- sort packages urls
function _sort_packages_urls(packages)

    -- add all urls to fasturl and prepare to sort them together
    for _, package in ipairs(packages) do
        fasturl.add(package:urls())
    end

    -- sort and update urls
    for _, package in ipairs(packages) do
        package:urls_set(fasturl.sort(package:urls()))
    end
end
  
-- check the configurations of packages
--
-- package("pcre2")
--      add_configs("bitwidth", {description = "Set the code unit width.", default = "8", values = {"8", "16", "32"}})
--      add_configs("bitwidth", {type = "number", values = {8, 16, 32}})
--      add_configs("bitwidth", {restrict = function(value) if tonumber(value) < 100 then return true end})
--
function _check_packages_configs(packages)
    for _, package in ipairs(packages) do
        local configs_defined = {}
        for _, name in ipairs(package:get("configs")) do
            configs_defined[name] = package:extraconf("configs", name) or {}
        end
        for name, value in pairs(package:configs()) do
            local conf = configs_defined[name]
            if conf then
                local config_type = conf.type or "string"
                if type(value) ~= config_type then
                    raise("package(%s %s): invalid type(%s) for config(%s), need type(%s)!", package:name(), package:version_str(), type(value), name, config_type)
                end
                if conf.values then
                    local found = false
                    for _, config_value in ipairs(conf.values) do
                        if tostring(value) == tostring(config_value) then
                            found = true
                            break
                        end
                    end
                    if not found then
                        raise("package(%s %s): invalid value(%s) for config(%s), please run `xmake require --info %s` to get all valid values!", package:name(), package:version_str(), value, name, package:name())
                    end
                end
                if conf.restrict then
                    if not conf.restrict(value) then
                        raise("package(%s %s): invalid value(%s) for config(%s)!", package:name(), package:version_str(), value, name)
                    end
                end
            else
                raise("package(%s %s): invalid config(%s), please run `xmake require --info %s` to get all configurations!", package:name(), package:version_str(), name, package:name())
            end
        end
    end
end

-- select packages version
function _select_packages_version(packages)

    -- sort and update urls
    for _, package in ipairs(packages) do

        -- exists urls? otherwise be phony package (only as package group)
        if #package:urls() > 0 then

            -- has git url?
            local has_giturl = false
            for _, url in ipairs(package:urls()) do
                if git.checkurl(url) then
                    has_giturl = true
                    break
                end
            end

            -- select package version
            local source = nil
            local version = nil
            local require_version = package:requireinfo().version
            if #package:versions() > 0 and (require_version == "lastest" or require_version:find('.', 1, true)) then -- select version?
                version, source = semver.select(require_version, package:versions())
            elseif has_giturl then -- select branch?
                version, source = require_version ~= "lastest" and require_version or "master", "branches"
            else
                raise("package(%s %s): not found!", package:name(), require_version)
            end

            -- save version to package
            package:version_set(version, source)
        end
    end
end

-- get user confirm
function _get_confirm(packages)

    -- no confirmed packages?
    if #packages == 0 then
        return true
    end

    -- get confirm
    local confirm = option.get("yes")
    if confirm == nil then

        -- get packages for each repositories
        local packages_repo = {}
        for _, package in ipairs(packages) do
            local reponame = package:repo() and package:repo():name() or (package:isSys() and "system" or "")
            if package:is3rd() then
                reponame = package:name():lower():split("::")[1]
            end
            packages_repo[reponame] = packages_repo[reponame] or {}
            table.insert(packages_repo[reponame], package)
        end

        -- show tips
        cprint("${bright color.warning}note: ${clear}try installing these packages (pass -y to skip confirm)?")
        for reponame, packages in pairs(packages_repo) do
            if reponame ~= "" then
                print("in %s:", reponame)
            end
            for _, package in ipairs(packages) do
                print("  -> %s %s %s", package:name(), package:version_str() or "", package:debug() and "(debug)" or "")
            end
        end
        cprint("please input: y (y/n)")

        -- get answer
        io.flush()
        local answer = io.read()
        if answer == 'y' or answer == '' then
            confirm = true
        end
    end

    -- ok?
    return confirm
end

-- the cache directory
function cachedir()
    return path.join(global.directory(), "cache", "packages")
end

-- load requires
function load_requires(requires, requires_extra, parentinfo)

    -- parse requires
    local requireinfos = {}
    for _, require_str in ipairs(requires) do

        -- parse require info
        local packagename, requireinfo = _parse_require(require_str, requires_extra, parentinfo)

        -- save this required package
        table.insert(requireinfos, {name = packagename, info = requireinfo})
    end

    -- ok
    return requireinfos
end

-- load all required packages
function load_packages(requires, opt)

    -- init options
    opt = opt or {}

    -- laod all required packages recursively
    local packages = _load_packages(requires, opt)

    -- select packages version
    _select_packages_version(packages)

    -- check the configurations of packages
    _check_packages_configs(packages)

    -- remove repeat packages with same the package name and version
    local unique = {}
    local results = {}
    for _, package in ipairs(packages) do
        local key = package:name() .. (package:version_str() or "")
        if not unique[key] then

            -- do load for package
            local on_load = package:script("load")
            if on_load then
                on_load(package)
            end

            -- add package
            table.insert(results, package)
            unique[key] = true
        end
    end
    return results
end

-- install packages
function install_packages(requires, opt)

    -- init options
    opt = opt or {}

    -- load packages
    local packages = load_packages(requires, opt)

    -- fetch packages (with system) from local first
    if not option.get("force") then 
        process.runjobs(function (index)
            local package = packages[index]
            if package then
                package:fetch()
            end
        end, #packages)
    end

    -- filter packages
    local packages_install = {}
    local packages_download = {}
    local packages_unsupported = {}
    for _, package in ipairs(packages) do
        if (option.get("force") or not package:exists()) and (#package:urls() > 0 or package:script("install")) then
            if package:supported() then
                if #package:urls() > 0 then
                    table.insert(packages_download, package)
                end
                table.insert(packages_install, package)
            elseif not package:optional() then
                table.insert(packages_unsupported, package)
            end
        end
    end

    -- exists unsupported packages?
    if #packages_unsupported > 0 then
        -- show tips
        cprint("${bright color.warning}note: ${clear}the following packages are unsupported for $(plat)/$(arch)!")
        for _, package in ipairs(packages_unsupported) do
            print("  -> %s %s", package:name(), package:version_str() or "")
        end
        raise()
    end

    -- get user confirm
    if not _get_confirm(packages_install) then
        return 
    end

    -- sort package urls
    _sort_packages_urls(packages_download)

    -- download remote packages
    local waitindex = 0
    local waitchars = {'\\', '|', '/', '-'}
    process.runjobs(function (index)

        local package = packages_download[index]
        if package then
            action.download(package)
        end

    end, #packages_download, ifelse((option.get("verbose") or option.get("diagnosis")), 1, 4), 300, function (indices) 

        -- do not print progress info if be verbose 
        if option.get("verbose") or option.get("diagnosis") then
            return 
        end
 
        -- update waitchar index
        waitindex = ((waitindex + 1) % #waitchars)

        -- make downloading packages list
        local downloading = {}
        for _, index in ipairs(indices) do
            local package = packages_download[index]
            if package then
                table.insert(downloading, package:name())
            end
        end
       
        -- trace
        cprintf("\r${yellow}  => ${clear}downloading %s .. %s", table.concat(downloading, ", "), waitchars[waitindex + 1])
        io.flush()
    end)

    -- install all required packages from repositories
    local installed_in_group = {}
    for _, package in ipairs(packages_install) do

        -- only install the first package in same group
        local group = package:group()
        if not group or not installed_in_group[group] then
            action.install(package)
            if group then
                installed_in_group[group] = true
            end
        end
    end

    -- ok
    return packages
end

-- uninstall packages
function uninstall_packages(requires, opt)

    -- init options
    opt = opt or {}

    -- do not remove dependent packages
    opt.nodeps = true

    -- clear the detect cache
    detectcache.clear()

    -- remove all packages
    local packages = {}
    for _, instance in ipairs(load_packages(requires, opt)) do
        if os.isfile(instance:manifest_file()) then
            table.insert(packages, instance)
        end
        os.tryrm(instance:installdir())
    end
    return packages
end

-- search packages
function search_packages(names)

    -- search all names
    local results = {}
    for _, name in ipairs(names) do
        local packages = _search_packages(name)
        if packages then
            results[name] = packages
        end
    end
    return results
end
