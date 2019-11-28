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
import parsetoml

import nimph/spec

type
  ProjectCfgParsed* = object
    table*: TableRef[string, string]
    why*: string
    ok*: bool

  NimphConfig* = ref object
    toml: TomlValueRef

proc loadProjectCfg*(path: string): Option[ConfigRef] =
  ## use the compiler to parse a nim.cfg
  var
    cache = newIdentCache()
    filename = path.absolutePath
    config = newConfigRef()
  if readConfigFile(filename.AbsoluteFile, cache, config):
    result = config.some

proc loadAllCfgs*(dir = ""): ConfigRef =
  ## use the compiler to parse all the usual nim.cfgs;
  ## optionally change to the given (project?) directory first

  if dir != "":
    setCurrentDir(dir)

  result = newConfigRef()

  # define symbols such as, say, nimbabel;
  # this allows us to correctly parse conditions in nim.cfg(s)
  initDefines(result.symbols)

  # maybe we should turn off configuration hints for these reads
  when not defined(debug):
    result.notes.excl hintConf
  when defined(debugPaths):
    result.notes.incl hintPath

  # stuff the prefixDir so we load the compiler's config/nim.cfg
  # just like the compiler would if we were to invoke it directly
  let compiler = getCurrentCompilerExe()
  result.prefixDir = AbsoluteDir splitPath(compiler.parentDir).head

  # stuff the current directory as the project path; this seems okay
  # for a loadAllCfgs call...
  result.projectPath = AbsoluteDir getCurrentDir()

  # now follow the compiler process of loading the configs
  var cache = newIdentCache()
  loadConfigs(NimCfg.RelativeFile, cache, result)

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

  try:
    # if there's already a config, we'll start there
    if fileExists($path):
      debug &"copying {path} to {temp}"
      copyFile($path, temp)
  except Exception as e:
    discard e
    return

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
    return

  # copy the temp file over the original config
  try:
    debug &"copying {temp} over {path}"
    copyFile(temp, $path)
  except Exception as e:
    discard e
    return

  # it worked, thank $deity
  result = true

proc parseProjectCfg*(input: Target): ProjectCfgParsed =
  ## parse a .cfg for any lines we are entitled to mess with
  result = ProjectCfgParsed(ok: false, table: newTable[string, string]())
  var
    content: string
    table = result.table

  if not fileExists($input):
    result.why = &"config file {input} doesn't exist"
    return

  try:
    content = readFile($input)
  except:
    result.why = &"i couldn't read {input}"
    return

  let
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
      return
    result.why = parsed.repr
  except Exception as e:
    result.why = &"parse error in {input}: {e.msg}"

proc isEmpty*(config: NimphConfig): bool =
  result = config.toml.kind == TomlValueKind.None

proc newNimphConfig*(path: string): NimphConfig =
  ## instantiate a new nimph config using the given path
  result = NimphConfig()
  if not path.fileExists:
    result.toml = newTNull()
  else:
    result.toml = parseFile(path)

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
  for path in paths:
    if exists and not path.dirExists:
      continue
    yield path

proc suggestNimbleDir*(config: ConfigRef; repo: string;
                       local = ""; global = ""): string =
  ## come up with a useful nimbleDir based upon what we find in the
  ## current configuration, the location of the project, and the provided
  ## suggestions for local or global package directories
  var
    local = local
    global = global

  block either:
    # if a local directory is suggested, see if we can confirm its use
    if local != "":
      assert local.endsWith(DirSep)
      {.warning: "look for a nimble packages file here?".}
      for search in config.likelySearch(repo, libsToo = false):
        if search.startsWith(local):
          result = local
          break either

    # otherwise, try to pick a global .nimble directory based upon lazy paths
    for search in config.likelyLazy(repo):
      {.warning: "maybe we should look for some nimble debris?".}
      if search.endsWith(PkgDir & DirSep):
        result = search.parentDir  # ie. the parent of pkgs
      else:
        result = search            # doesn't look like pkgs... just use it
      break either

    # otherwise, try to make one up using the suggestion
    if global == "":
      raise newException(IOError, "unable to guess global {dotNimble} directory")
    assert global.endsWith(DirSep)
    result = global
    break either

iterator pathSubstitutions(config: ConfigRef; path: string;
                           conf: string; write: bool): string =
  ## compute the possible path substitions, including the original path
  const
    readSubs = @["nimcache", "config", "nimbledir", "nimblepath",
                 "projectdir", "projectpath", "lib", "nim", "home"]
    writeSubs = @["nimcache", "config", "projectdir", "lib", "nim", "home"]
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
    let attempt = config.pathSubs(&"${sub}", conf) / ""
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

proc removeSearchPath*(nimcfg: Target; path: string): bool =
  ## try to remove a path from a nim.cfg; true if it was
  ## successful and false if any error prevented success
  let
    fn = $nimcfg
  if not fn.fileExists:
    return
  let
    cfg = fn.loadProjectCfg
    parsed = nimcfg.parseProjectCfg
  if cfg.isNone:
    error &"the compiler couldn't parse {nimcfg}"
    return

  if not parsed.ok:
    error &"i couldn't parse {nimcfg}:"
    error parsed.why
    return
  var
    content = fn.readFile
  when defined(debug):
    if path.absolutePath != path:
      raise newException(Defect, &"path `{path}` is not absolute")
  for key, value in parsed.table.pairs:
    if key.toLowerAscii notin ["p", "path", "nimblepath"]:
      continue
    for sub in cfg.get.pathSubstitutions(path, nimcfg.repo, write = false):
      if sub notin [value, value / ""]:
        continue
      let
        regexp = re("(*ANYCRLF)(?i)(?s)(-{0,2}" & key.escapeRe & "[:=]\"?" &
                    value.escapeRe & "/?\"?)\\s*")
        swapped = content.replace(regexp, "")
      if swapped == content:
        continue
      # make sure we search the new content next time through the loop
      content = swapped
      fn.writeFile(content)
      result = true

proc addSearchPath*(config: ConfigRef; nimcfg: Target; path: string): bool =
  let
    best = config.bestPathSubstitution(path, $nimcfg.repo)
  result = appendConfig(nimcfg, &"""--path="{best}"""")

proc excludeSearchPath*(nimcfg: Target; path: string): bool =
  result = appendConfig(nimcfg, &"""--excludePath="{path}"""")

iterator extantSearchPaths*(config: ConfigRef; least = 0): string =
  ## yield existing search paths from the configuration as /-terminated strings
  if config == nil:
    raise newException(Defect, "attempt to load search paths from nil config")
  for path in config.likelySearch(libsToo = true):
    if dirExists(path):
      yield path
  for path in config.likelyLazy(least = least):
    if dirExists(path):
      yield path
