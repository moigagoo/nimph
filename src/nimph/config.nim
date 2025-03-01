import std/json
import std/nre
import std/strtabs
import std/strformat
import std/tables
import std/os
import std/options
import std/strutils
import std/algorithm

import compiler/idents
import compiler/nimconf
import compiler/options as compileropts
import compiler/pathutils
import compiler/condsyms
import compiler/lineinfos

export compileropts
export nimconf

import npeg
import bump

import nimph/spec

when defined(debugPath):
  from std/sequtils import count

type
  ProjectCfgParsed* = object
    table*: TableRef[string, string]
    why*: string
    ok*: bool

  ConfigSection = enum
    LockerRooms = "lockfiles"

  NimphConfig* = ref object
    path: string
    js: JsonNode

proc loadProjectCfg*(path: string): Option[ConfigRef] =
  ## use the compiler to parse a nim.cfg
  var
    cache = newIdentCache()
    filename = path.absolutePath
    config = newConfigRef()
  if readConfigFile(filename.AbsoluteFile, cache, config):
    result = config.some

proc overlayConfig*(config: var ConfigRef; directory: string): bool =
  ## true if new config data was added to the env
  withinDirectory(directory):
    var
      priorProjectPath = config.projectPath
    let
      nextProjectPath = AbsoluteDir getCurrentDir()
      filename = nextProjectPath.string / NimCfg

    block complete:
      # if there's no config file, we're done
      result = filename.fileExists
      if not result:
        break complete

      # remember to reset the config's project path
      defer:
        config.projectPath = priorProjectPath
      # set the new project path for substitution purposes
      config.projectPath = nextProjectPath

      var cache = newIdentCache()
      result = readConfigFile(filename.AbsoluteFile, cache, config)

      if result:
        # this config is now authoritative, so force the project path
        priorProjectPath = nextProjectPath
      else:
        let emsg = &"unable to read config in {nextProjectPath}" # noqa
        warn emsg

proc loadAllCfgs*(directory: string): ConfigRef =
  ## use the compiler to parse all the usual nim.cfgs;
  ## optionally change to the given (project?) directory first

  result = newConfigRef()

  # define symbols such as, say, nimbabel;
  # this allows us to correctly parse conditions in nim.cfg(s)
  initDefines(result.symbols)

  # maybe we should turn off configuration hints for these reads
  when not defined(debug) and not defined(debugPath):
    result.notes.excl hintConf
  result.notes.excl hintLineTooLong
  when defined(debugPath):
    result.notes.incl hintPath

  # stuff the prefixDir so we load the compiler's config/nim.cfg
  # just like the compiler would if we were to invoke it directly
  let compiler = getCurrentCompilerExe()
  result.prefixDir = AbsoluteDir splitPath(compiler.parentDir).head

  withinDirectory(directory):
    # stuff the current directory as the project path
    result.projectPath = AbsoluteDir getCurrentDir()

    # now follow the compiler process of loading the configs
    var cache = newIdentCache()
    loadConfigs(NimCfg.RelativeFile, cache, result)
  when defined(debugPath):
    debug "loaded", result.searchPaths.len, "search paths"
    debug "loaded", result.lazyPaths.len, "lazy paths"
    for path in result.lazyPaths.items:
      if result.lazyPaths.count(path) > 1:
        raise newException(Defect, "duplicate lazy path: " & path.string)

proc appendConfig*(path: Target; config: string): bool =
  # make a temp file in an appropriate spot, with a significant name
  let
    temp = createTemporaryFile(path.package, dotNimble)
  debug &"writing {temp}"
  # but remember to remove the temp file later
  defer:
    debug &"removing {temp}"
    if not tryRemoveFile(temp):
      warn &"unable to remove temporary file `{temp}`"

  block complete:
    try:
      # if there's already a config, we'll start there
      if fileExists($path):
        debug &"copying {path} to {temp}"
        copyFile($path, temp)
    except Exception as e:
      warn &"unable make a copy of {path} to to {temp}: {e.msg}"
      break complete

    block writing:
      # open our temp file for writing
      var
        writer = temp.open(fmAppend)
      # but remember to close the temp file in any event
      defer:
        writer.close

      # add our new content with a trailing newline
      writer.writeLine config

    # make sure the compiler can parse our new config
    let
      parsed = loadProjectCfg(temp)
    if parsed.isNone:
      break complete

    # copy the temp file over the original config
    try:
      debug &"copying {temp} over {path}"
      copyFile(temp, $path)
    except Exception as e:
      warn &"unable make a copy of {temp} to to {path}: {e.msg}"
      break complete

    # it worked, thank $deity
    result = true

proc parseProjectCfg*(input: Target): ProjectCfgParsed =
  ## parse a .cfg for any lines we are entitled to mess with
  result = ProjectCfgParsed(ok: false, table: newTable[string, string]())
  var
    table = result.table

  block success:
    if not fileExists($input):
      result.why = &"config file {input} doesn't exist"
      break success

    let
      content = readFile($input)
      peggy = peg "document":
        nl <- ?'\r' * '\n'
        white <- {'\t', ' '}
        equals <- *white * {'=', ':'} * *white
        assignment <- +(1 - equals)
        comment <- '#' * *(1 - nl)
        strvalue <- '"' * *(1 - '"') * '"'
        endofval <- white | comment | nl
        anyvalue <- +(1 - endofval)
        hyphens <- '-'[0..2]
        ending <- *white * ?comment * nl
        nimblekeys <- i"nimblePath" | i"clearNimblePath" | i"noNimblePath"
        otherkeys <- i"path" | i"p" | i"define" | i"d"
        keys <- nimblekeys | otherkeys
        strsetting <- hyphens * >keys * equals * >strvalue * ending:
          table.add $1, unescape($2)
        anysetting <- hyphens * >keys * equals * >anyvalue * ending:
          table.add $1, $2
        toggle <- hyphens * >keys * ending:
          table.add $1, "it's enabled, okay?"
        line <- strsetting | anysetting | toggle | (*(1 - nl) * nl)
        document <- *line * !1
      parsed = peggy.match(content)
    try:
      result.ok = parsed.ok
      if result.ok:
        break success
      result.why = parsed.repr
    except Exception as e:
      result.why = &"parse error in {input}: {e.msg}"

proc isEmpty*(config: NimphConfig): bool =
  result = config.js.kind == JNull

proc newNimphConfig*(path: string): NimphConfig =
  ## instantiate a new nimph config using the given path
  result = NimphConfig(path: path.absolutePath)
  if not result.path.fileExists:
    result.js = newJNull()
  else:
    try:
      result.js = parseFile(path)
    except Exception as e:
      error &"unable to parse {path}:"
      error e.msg

template isStdLib*(config: ConfigRef; path: string): bool =
  path.startsWith(config.libpath.string / "")

template isStdlib*(config: ConfigRef; path: AbsoluteDir): bool =
  path.string.isStdLib

iterator likelySearch*(config: ConfigRef; libsToo: bool): string =
  ## yield /-terminated directory paths likely added via --path
  for search in config.searchPaths.items:
    let search = search.string / "" # cast from AbsoluteDir
    # we don't care about library paths
    if not libsToo and config.isStdLib(search):
      continue
    yield search

iterator likelySearch*(config: ConfigRef; repo: string; libsToo: bool): string =
  ## yield /-terminated directory paths likely added via --path
  when defined(debug):
    if repo != repo.absolutePath:
      error &"repo {repo} wasn't normalized"

  for search in config.likelySearch(libsToo = libsToo):
    # limit ourselves to the repo?
    when WhatHappensInVegas:
      if search.startsWith(repo):
        yield search
    else:
      yield search

iterator likelyLazy*(config: ConfigRef; least = 0): string =
  ## yield /-terminated directory paths likely added via --nimblePath
  # build a table of sightings of directories
  var popular = newCountTable[string]()
  for search in config.lazyPaths.items:
    let
      search = search.string / ""      # cast from AbsoluteDir
      parent = search.parentDir / ""   # ensure a trailing /
    when defined(debugPath):
      if search in popular:
        raise newException(Defect, "duplicate lazy path: " & search)
    if search notin popular:
      popular.inc search
    if search != parent:               # silly: elide /
      if parent in popular:            # the parent has to have been added
        popular.inc parent

  # sort the table in descending order
  popular.sort

  # yield the directories that exist
  for search, count in popular.pairs:
    # maybe we can ignore unpopular paths
    if least > count:
      continue
    yield search

iterator likelyLazy*(config: ConfigRef; repo: string; least = 0): string =
  ## yield /-terminated directory paths likely added via --nimblePath
  when defined(debug):
    if repo != repo.absolutePath:
      error &"repo {repo} wasn't normalized"

  for search in config.likelyLazy(least = least):
    # limit ourselves to the repo?
    when WhatHappensInVegas:
      if search.startsWith(repo):
        yield search
    else:
      yield search

iterator packagePaths*(config: ConfigRef; exists = true): string =
  ## yield package paths from the configuration as /-terminated strings;
  ## if the exists flag is passed, then the path must also exist.
  ## this should closely mimic the compiler's search

  # the method by which we de-dupe paths
  const mode =
    when FilesystemCaseSensitive:
      modeCaseSensitive
    else:
      modeCaseInsensitive
  var
    paths: seq[string]
    dedupe = newStringTable(mode)

  template addOne(p: AbsoluteDir) =
    let path = path.string / ""
    if path in dedupe:
      continue
    dedupe[path] = ""
    paths.add path

  if config == nil:
    raise newException(Defect, "attempt to load search paths from nil config")

  for path in config.searchPaths:
    addOne(path)
  for path in config.lazyPaths:
    addOne(path)
  when defined(debugPath):
    debug &"package directory count: {paths.len}"

  # finally, emit paths as appropriate
  for path in paths:
    if exists and not path.dirExists:
      continue
    yield path

proc suggestNimbleDir*(config: ConfigRef; local = ""; global = ""): string =
  ## come up with a useful nimbleDir based upon what we find in the
  ## current configuration, the location of the project, and the provided
  ## suggestions for local or global package directories
  var
    local = local
    global = global

  block either:
    # if a local directory is suggested, see if we can confirm its use
    if local != "" and local.dirExists:
      assert local.endsWith(DirSep)
      for search in config.likelySearch(libsToo = false):
        if search.startsWith(local):
          # we've got a path statement pointing to a local path,
          # so let's assume that the suggested local path is legit
          result = local
          break either

    # nim 1.1.1 supports nimblePath storage in the config;
    # we follow a "standard" that we expect Nimble to use,
    # too, wherein the last-added --nimblePath wins
    when NimMajor >= 1 and NimMinor >= 1:
      if config.nimblePaths.len > 0:
        result = config.nimblePaths[0].string
        break either

    # otherwise, try to pick a global .nimble directory based upon lazy paths
    for search in config.likelyLazy:
      if search.endsWith(PkgDir & DirSep):
        result = search.parentDir  # ie. the parent of pkgs
      else:
        result = search            # doesn't look like pkgs... just use it
      break either

    # otherwise, try to make one up using the suggestion
    if global == "":
      raise newException(IOError, "can't guess global {dotNimble} directory")
    assert global.endsWith(DirSep)
    result = global
    break either

iterator pathSubsFor(config: ConfigRef; sub: string; conf: string): string =
  ## a convenience to work around the compiler's broken pathSubs; the `conf`
  ## string represents the path to the "current" configuration file
  block:
    if sub.toLowerAscii notin ["nimbledir", "nimblepath"]:
      yield config.pathSubs(&"${sub}", conf) / ""
      break

    when declaredInScope nimbleSubs:
      for path in config.nimbleSubs(&"${sub}"):
        yield path / ""
    else:
      # we have to pick the first lazy path because that's what Nimble does
      for search in config.lazyPaths:
        let search = search.string / ""
        if search.endsWith(PkgDir & DirSep):
          yield search.parentDir / ""
        else:
          yield search
        break

iterator pathSubstitutions(config: ConfigRef; path: string;
                           conf: string; write: bool): string =
  ## compute the possible path substitions, including the original path
  const
    readSubs = @["nimcache", "config", "nimbledir", "nimblepath",
                 "projectdir", "projectpath", "lib", "nim", "home"]
    writeSubs =
      when writeNimbleDirPaths:
        readSubs
      else:
        @["nimcache", "config", "projectdir", "lib", "nim", "home"]
  var
    matchedPath = false
  when defined(debug):
    if not conf.dirExists:
      raise newException(Defect, "passed a config file and not its path")
  let
    path = path / ""
    conf = if conf.dirExists: conf else: conf.parentDir
    substitutions = if write: writeSubs else: readSubs

  for sub in substitutions.items:
    for attempt in config.pathSubsFor(sub, conf):
      # ignore any empty substitutions
      if attempt == "/":
        continue
      # note if any substitution matches the path
      if path == attempt:
        matchedPath = true
      if path.startsWith(attempt):
        yield path.replace(attempt, &"${sub}" / "")
  # if a substitution matches the path, don't yield it at the end
  if not matchedPath:
    yield path

proc bestPathSubstitution(config: ConfigRef; path: string; conf: string): string =
  ## compute the best path substitution, if any
  block found:
    for sub in config.pathSubstitutions(path, conf, write = true):
      result = sub
      break found
    result = path

proc removeSearchPath*(config: ConfigRef; nimcfg: Target; path: string): bool =
  ## try to remove a path from a nim.cfg; true if it was
  ## successful and false if any error prevented success
  let
    fn = $nimcfg

  block complete:
    # well, that was easy
    if not fn.fileExists:
      break complete

    # make sure we can parse the configuration with the compiler
    let
      cfg = fn.loadProjectCfg
    if cfg.isNone:
      error &"the compiler couldn't parse {nimcfg}"
      break complete

    # make sure we can parse the configuration using our "naive" npeg parser
    let
      parsed = nimcfg.parseProjectCfg
    if not parsed.ok:
      error &"could not parse {nimcfg} naïvely:"
      error parsed.why
      break complete

    # sanity
    when defined(debug):
      if path.absolutePath != path:
        raise newException(Defect, &"path `{path}` is not absolute")

    var
      content = fn.readFile
    # iterate over the entries we parsed naively,
    for key, value in parsed.table.pairs:
      # skipping anything that it's a path,
      if key.toLowerAscii notin ["p", "path", "nimblepath"]:
        continue
      # and perform substitutions to see if one might match the value
      # we are trying to remove; the write flag is false so that we'll
      # use any $nimbleDir substitutions available to us, if possible
      for sub in config.pathSubstitutions(path, nimcfg.repo, write = false):
        if sub notin [value, value / ""]:
          continue
        # perform a regexp substition to remove the entry from the content
        let
          regexp = re("(*ANYCRLF)(?i)(?s)(-{0,2}" & key.escapeRe &
                      "[:=]\"?" & value.escapeRe & "/?\"?)\\s*")
          swapped = content.replace(regexp, "")
        # if that didn't work, cry a bit and move on
        if swapped == content:
          notice &"failed regex edit to remove path `{value}`"
          continue
        # make sure we search the new content next time through the loop
        content = swapped
        result = true
        # keep performing more substitutions

    # finally, write the edited content
    fn.writeFile(content)

proc addSearchPath*(config: ConfigRef; nimcfg: Target; path: string): bool =
  ## add the given path to the given config file, using the compiler's
  ## configuration as input to determine the best path substitution
  let
    best = config.bestPathSubstitution(path, $nimcfg.repo)
  result = appendConfig(nimcfg, &"""--path="{best}"""")

proc excludeSearchPath*(config: ConfigRef; nimcfg: Target; path: string): bool =
  ## add an exclusion for the given path to the given config file, using the
  ## compiler's configuration as input to determine the best path substitution
  let
    best = config.bestPathSubstitution(path, $nimcfg.repo)
  result = appendConfig(nimcfg, &"""--excludePath="{best}"""")

iterator extantSearchPaths*(config: ConfigRef; least = 0): string =
  ## yield existing search paths from the configuration as /-terminated strings;
  ## this will yield library paths and nimblePaths with at least `least` uses
  if config == nil:
    raise newException(Defect, "attempt to load search paths from nil config")
  # path statements
  for path in config.likelySearch(libsToo = true):
    if dirExists(path):
      yield path
  # nimblePath statements
  for path in config.likelyLazy(least = least):
    if dirExists(path):
      yield path

proc addLockerRoom*(config: var NimphConfig; name: string; room: JsonNode) =
  ## add the named lockfile (in json form) to the configuration file
  if config.isEmpty:
    config.js = newJObject()
  if $LockerRooms notin config.js:
    config.js[$LockerRooms] = newJObject()
  config.js[$LockerRooms][name] = room
  writeFile(config.path, config.js.pretty)

proc getAllLockerRooms*(config: NimphConfig): JsonNode =
  ## retrieve a JObject holding all lockfiles in the configuration file
  block found:
    if not config.isEmpty:
      if $LockerRooms in config.js:
        result = config.js[$LockerRooms]
        break
    result = newJObject()

proc getLockerRoom*(config: NimphConfig; name: string): JsonNode =
  ## retrieve the named lockfile (or JNull) from the configuration
  let
    rooms = config.getAllLockerRooms
  if name in rooms:
    result = rooms[name]
  else:
    result = newJNull()
