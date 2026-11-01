#
#           Jorogumo — Leng → JavaScript code generator
#        (c) Copyright 2026 Andreas Rumpf
#
#    See the file "license.txt", included in this distribution, for
#    details about the copyright.
##

## Tests for the static layout and the data image (`codegen`): every global
## gets an address, a constant's fields land where the layout rules say, an
## address-valued field is a fixup resolved at layout time, and the whole image
## really is in linear memory — checked by a JS ENGINE reading it back through
## the pointer, not by inspecting the emitted text.
##
## Run: `nim c -r tcodegen.nim`. Without `node` the engine check is skipped and
## the skip is reported.

import std / [os, osproc, strutils, tables]
import nifcore, nifcoreparse
import "../arkham/core" / lengdecl
import webnif, codegen, jsrender

proc check(label: string; cond: bool; detail = "") =
  if not cond:
    echo "FAIL ", label
    if detail.len > 0: echo "  ", detail
    quit 1
  echo "ok ", label

proc must(label: string; cond: bool; detail = "") =
  ## An invariant of the test's own helpers: silent unless it breaks, so the
  ## report lists what is being asserted about the layout, not bookkeeping.
  if not cond:
    echo "FAIL (helper) ", label
    if detail.len > 0: echo "  ", detail
    quit 1

proc expect(label: string; got, want: string) =
  check label, got == want, "got: " & got & "  want: " & want

proc findAddr(g: WebGen; part: string): uint32 =
  ## The address of the one global whose name contains `part` — the names in
  ## the fixture carry a trailing `.` that the NIF API completes to the module
  ## suffix, so matching on the whole name would be guessing at that.
  result = 0
  for sym, a in g.globalAddr:
    let name = poolSym(g.lengPool, sym)   # the layout is keyed by POOL ID; the
    if name.contains(part):               # spelling is what a test matches on
      must "unique " & part, result == 0, "both " & name & " and the previous match"
      result = a

proc segAt(g: WebGen; a: uint32): string =
  ## The image bytes that land at `address` `a`.
  result = ""
  for (at, s) in g.dataSegs:
    if at == a:
      must "one segment per address", result.len == 0
      result = s

proc u32at(s: string; off: int): uint32 =
  must "u32 in range", off + 4 <= s.len, "segment of " & $s.len & " bytes, offset " & $off
  uint32(uint8(s[off])) or (uint32(uint8(s[off + 1])) shl 8) or
    (uint32(uint8(s[off + 2])) shl 16) or (uint32(uint8(s[off + 3])) shl 24)

proc fixturePath: string =
  for dir in ["", getCurrentDir() / "fixtures", getAppDir() / "fixtures",
              getAppDir() / "../fixtures", getAppDir() / "../src/web/fixtures"]:
    let p = dir / "tdata1.c.nif"
    if fileExists(p): return p
  quit "tcodegen: fixtures/tdata1.c.nif not found"

let tags = createLengTagPool()   # NOT the web IR pool: a buffer is Leng-tagged or JS-tagged, never both

if paramCount() == 2 and paramStr(1) == "--generate":
  # Child mode for the refusal checks: `refuse` quits, so a refusal is read off
  # a process, not caught.
  var cbuf = parseFromFile(paramStr(2), sharedTags = tags)
  var cm = default(WebModule)
  discard generate(cbuf, paramStr(2), tags, wtJs, cm)
  quit 0

let path = fixturePath()
var buf = parseFromFile(path, sharedTags = tags)
var g = createWebGen(buf, path, tags)
layoutProgram(g)

check "layout starts above the null guard", g.memTop > NullGuard, $g.memTop
let
  strA = findAddr(g, "HELLO")
  wordsA = findAddr(g, "words")
  ptrsA = findAddr(g, "ptrs")
  guardA = findAddr(g, "guard")
  wideA = findAddr(g, "wide")
  msgA = findAddr(g, "msg")
check "globals are distinct",
  strA != wordsA and strA != ptrsA and guardA != wideA and msgA != strA

# the object constant: fields at their layout offsets, the flexarray tail
# carrying the payload inline (a tail is not a pointer).
let strSeg = segAt(g, strA)
check "const image is fixed part + payload", strSeg.len == 8 + 15, $strSeg.len
expect "fullLen at offset 0", $u32at(strSeg, 0), "14"
check "rc is zero (not initialized)", u32at(strSeg, 4) == 0
expect "flexarray tail at offset 8", strSeg[8 .. 22], "hello jorogumo\0"

# an array constant: elements at the element stride.
let wordsSeg = segAt(g, wordsA)
check "3 i32 elements", wordsSeg.len == 12, $wordsSeg.len
expect "array elements", $u32at(wordsSeg, 0) & "," & $u32at(wordsSeg, 4) & "," &
  $u32at(wordsSeg, 8), "7,8,9"

# fixups: a proc symbol becomes its function-table slot, a nil slot stays 0.
let ptrsSeg = segAt(g, ptrsA)
check "2 pointer slots", ptrsSeg.len == 8, $ptrsSeg.len
check "proc symbol → function-table slot", u32at(ptrsSeg, 0) >= 1, $u32at(ptrsSeg, 0)
check "nil slot is zero", u32at(ptrsSeg, 4) == 0

# a `(addr g)` initializer resolves to the global's own address — the fixup
# this module exists to resolve.
let msgSeg = segAt(g, msgA)
check "addr fixup is one word", msgSeg.len == 4, $msgSeg.len
expect "addr fixup points at the const", $u32at(msgSeg, 0), $strA

# zero-initialized globals reserve space only: no bytes to store.
check "zero-init gvar has no segment", segAt(g, guardA).len == 0
check "but it does have an address", guardA >= NullGuard

# a 64-bit initializer is not truncated by the little-endian writer.
let wideSeg = segAt(g, wideA)
check "i64 image is 8 bytes", wideSeg.len == 8, $wideSeg.len
var wide = 0'u64
for i in 0 ..< 8: wide = wide or (uint64(uint8(wideSeg[i])) shl (8 * i))
expect "i64 initializer", $wide, "4294967296"

# the emitted image is self-describing: one loader call per segment.
let image = dataInitJs(WebModule(dataSegs: g.dataSegs, memTop: g.memTop))
check "one loader call per segment",
  image.count('\n') == g.dataSegs.len, $g.dataSegs.len

# ── the engine is the judge: read the image back through the pointer ────────

let nodeExe = findExe("node")
if nodeExe.len == 0:
  echo "skip engine check: node not on PATH"
else:
  let probe = """
function rd(at) { let s = ""; for (;;) { const c = U8[at]; if (c === 0) break; s += String.fromCharCode(c); ++at; } return s; }
console.log(U32[$1 / 4]);
console.log(rd($1 + 8));
console.log(String(U32[$2 / 4] === $1));
console.log(String(BU64[$3 / 8]));
console.log([U32[$4 / 4], U32[$4 / 4 + 1], U32[$4 / 4 + 2]].join(","));
console.log([U32[$5 / 4], U32[$5 / 4 + 1]].join(","));
console.log(U8[$6]);
""".replace("$1", $strA).replace("$2", $msgA).replace("$3", $wideA)
   .replace("$4", $wordsA).replace("$5", $ptrsA).replace("$6", $guardA)
  let jsPath = getTempDir() / "jorogumo_layout_" & $getCurrentProcessId() & ".js"
  writeFile(jsPath, jsPreamble(64 * 1024, 64 * 1024, 4096) & image & probe)
  defer: removeFile(jsPath)
  let r = execCmdEx(nodeExe & " " & quoteShell(jsPath))
  expect "engine reads the image back", strip(r.output),
    "14\nhello jorogumo\ntrue\n4294967296\n7,8,9\n1,0\n0"

  # The frame plan and the lowering walk the same tree. An `importjs` string
  # splice takes a frame temporary for its result (a handle or cstring splice
  # takes none); a mismatch shifted every later temporary (a 12-byte
  # constructor met an 8-byte slot).
  # `fixtures/tsplice.c.nif` splices a string, builds a pair of strings and
  # passes a constructor to a call; 3 + 3 + (5 + 7 + 11) is the exit code.
  let splicePath = path.parentDir / "tsplice.c.nif"
  var sbuf = parseFromFile(splicePath, sharedTags = tags)
  var sm = default(WebModule)
  var stree = generate(sbuf, splicePath, tags, wtJs, sm)
  let spliceJs = getTempDir() / "jorogumo_splice_" & $getCurrentProcessId() & ".js"
  writeFile(spliceJs, renderJs(stree, sm, 64 * 1024 * 1024, 64 * 1024))
  defer: removeFile(spliceJs)
  let sr = execCmdEx(nodeExe & " " & quoteShell(spliceJs))
  check "splice then constructors: the plan matches the lowering",
    sr.exitCode == 29, "exit " & $sr.exitCode & "\n" & sr.output

# A string an `importjs` proc returns is an ordinary owned Nim string, built in
# a frame temporary of the caller. `fixtures/tstrbridge.c.nif` splices strings
# of 0, 3, 6 (the inline payload limit), 7 and 10 chars: only a string past the
# payload allocates. The fixture stubs the runtime's `nimStrBeginStore` and
# `nimStrEndStore` (the bridge writes no layout of its own, it only calls them
# and copies the bytes), and each string is checked by what it reads as; two
# live results of one expression do not share a slot; every begin has its end.
let sgPath = path.parentDir / "tstrbridge.c.nif"
var sgBuf = parseFromFile(sgPath, sharedTags = tags)
var sgMod = default(WebModule)
var sgTree = generate(sgBuf, sgPath, tags, wtJs, sgMod)
let sgJs = getTempDir() / "jorogumo_strbridge_" & $getCurrentProcessId() & ".js"
writeFile(sgJs, renderJs(sgTree, sgMod, 64 * 1024 * 1024, 64 * 1024))
if nodeExe.len > 0:
  let sgr = execCmdEx(nodeExe & " " & quoteShell(sgJs))
  removeFile(sgJs)
  check "bridged strings: inline up to the payload, Nim-built string",
    sgr.exitCode == 63, "exit " & $sgr.exitCode & "\n" & sgr.output

# `importjs` callbacks run end to end. `fixtures/tcallback.c.nif` fires a named
# proc and a stored fn-ptr with `null`, `undefined`, an object, a function and a
# number: the first two must arrive as nil (+1 each), the object and the
# function as handles (+2 each), the number untouched (+16).
let cbPath = path.parentDir / "tcallback.c.nif"
var cbBuf = parseFromFile(cbPath, sharedTags = tags)
var cbMod = default(WebModule)
var cbTree = generate(cbBuf, cbPath, tags, wtJs, cbMod)
let cbJs = getTempDir() / "jorogumo_callback_" & $getCurrentProcessId() & ".js"
writeFile(cbJs, renderJs(cbTree, cbMod, 64 * 1024 * 1024, 64 * 1024))
if nodeExe.len > 0:
  let cr = execCmdEx(nodeExe & " " & quoteShell(cbJs))
  removeFile(cbJs)
  check "handle callback arguments: null, undefined, object, function, number",
    cr.exitCode == 22, "exit " & $cr.exitCode & "\n" & cr.output

# Handle identity (doc/web.md): `fixtures/thandle.c.nif` takes `globalThis`
# twice (equal handles, +1), two fresh objects (different handles, +2), a
# handle through an `importjs` identity splice (+4), and checks that a crossing
# STORES the huge count into the cell at offset 0 even after the program
# clobbered it (+8) and that the handle is a 16-aligned address (+16).
let hdPath = path.parentDir / "thandle.c.nif"
var hdBuf = parseFromFile(hdPath, sharedTags = tags)
var hdMod = default(WebModule)
var hdTree = generate(hdBuf, hdPath, tags, wtJs, hdMod)
let hdJs = getTempDir() / "jorogumo_handle_" & $getCurrentProcessId() & ".js"
writeFile(hdJs, renderJs(hdTree, hdMod, 64 * 1024 * 1024, 64 * 1024))
if nodeExe.len > 0:
  let hr = execCmdEx(nodeExe & " " & quoteShell(hdJs))
  removeFile(hdJs)
  check "handle identity: one JS value, one handle; the cell count is restored",
    hr.exitCode == 31, "exit " & $hr.exitCode & "\n" & hr.output

# A callback that returns a `string` (an aggregate, through the hidden first
# parameter): `fixtures/tcbstring.c.nif` fires one with a parameter and one
# with none, each as a named proc and as a stored fn-ptr. The host must see
# "alphabet" and "zero" (1 + 1 + 2 + 2). Each of the four returned strings is
# destroyed once, after its conversion, and so is each of the two "alphabet"
# arguments the wrapper built for the borrowed parameter (6 * 16); each of
# those two were built long by the store entry points (2 * 64), "zero" fits
# inline.
let sbPath = path.parentDir / "tcbstring.c.nif"
var sbBuf = parseFromFile(sbPath, sharedTags = tags)
var sbMod = default(WebModule)
var sbTree = generate(sbBuf, sbPath, tags, wtJs, sbMod)
let sbJs = getTempDir() / "jorogumo_cbstring_" & $getCurrentProcessId() & ".js"
writeFile(sbJs, renderJs(sbTree, sbMod, 64 * 1024 * 1024, 64 * 1024))
if nodeExe.len > 0:
  let sr2 = execCmdEx(nodeExe & " " & quoteShell(sbJs))
  removeFile(sbJs)
  check "string-result callbacks: arguments, no parameters, fn-ptr; result destroyed",
    sr2.exitCode == 230, "exit " & $sr2.exitCode & "\n" & sr2.output

# Case labels. `fixtures/tcase.c.nif` switches u64 scrutinees: a range at the
# top of the u64 domain (+1), a label above 2^53 that its neighbour must not
# match (+2, +4). The branches are `(scope ...)`, as hexer emits the empty
# arms of a variant object's `=destroy`.
let csPath = path.parentDir / "tcase.c.nif"
var csBuf = parseFromFile(csPath, sharedTags = tags)
var csMod = default(WebModule)
var csTree = generate(csBuf, csPath, tags, wtJs, csMod)
let csJs = getTempDir() / "jorogumo_case_" & $getCurrentProcessId() & ".js"
writeFile(csJs, renderJs(csTree, csMod, 64 * 1024 * 1024, 64 * 1024))
if nodeExe.len > 0:
  let csr = execCmdEx(nodeExe & " " & quoteShell(csJs))
  removeFile(csJs)
  check "case labels: u64 labels past 2^53, scope bodies",
    csr.exitCode == 7, "exit " & $csr.exitCode & "\n" & csr.output

# JS null and undefined at the bridge. `fixtures/tcnil.c.nif` fires a callback
# that takes a `cstring` with null (the nil cstring, +1) and with "abc" three
# times (borrowed bytes in the wrapper's frame, NUL-terminated, +2 each); a nil
# stored proc, a nil cstring and a splice returning null reach JS as null
# (+16, +32, +64); one Nim proc handed over as a stored value and as a
# named proc is the same JS function (+128).
let nlPath = path.parentDir / "tcnil.c.nif"
var nlBuf = parseFromFile(nlPath, sharedTags = tags)
var nlMod = default(WebModule)
var nlTree = generate(nlBuf, nlPath, tags, wtJs, nlMod)
let nlJs = getTempDir() / "jorogumo_cnil_" & $getCurrentProcessId() & ".js"
writeFile(nlJs, renderJs(nlTree, nlMod, 64 * 1024 * 1024, 64 * 1024))
if nodeExe.len > 0:
  let nlr = execCmdEx(nodeExe & " " & quoteShell(nlJs))
  removeFile(nlJs)
  check "null at the bridge: nil cstring, nil proc, callback cstring in the frame",
    nlr.exitCode == 247, "exit " & $nlr.exitCode & "\n" & nlr.output

# A store whose value grows memory. `fixtures/tgrowstore.c.nif` stores the
# first handle ever made (its cell page grows linear memory) into a global:
# the store must land in the NEW buffer, not the one JS had read `DV` from
# before the call. A lost store leaves the global nil (exit 3, not 5).
let gsPath = path.parentDir / "tgrowstore.c.nif"
var gsBuf = parseFromFile(gsPath, sharedTags = tags)
var gsMod = default(WebModule)
var gsTree = generate(gsBuf, gsPath, tags, wtJs, gsMod)
let gsJs = getTempDir() / "jorogumo_growstore_" & $getCurrentProcessId() & ".js"
writeFile(gsJs, renderJs(gsTree, gsMod, 64 * 1024 * 1024, 64 * 1024))
if nodeExe.len > 0:
  let gsr = execCmdEx(nodeExe & " " & quoteShell(gsJs))
  removeFile(gsJs)
  check "a store whose value grows memory lands in the live buffer",
    gsr.exitCode == 5, "exit " & $gsr.exitCode & "\n" & gsr.output

# A plain aggregate has no JS spelling as a splice RESULT (an argument is its
# address): refused, naming the proc, rather than read back as garbage.
proc refusal(fixture: string): (string, int) =
  execCmdEx(quoteShell(getAppFilename()) & " --generate " &
            quoteShell(path.parentDir / fixture & ".c.nif"),
            options = {poStdErrToStdOut})

let (aggOut, aggCode) = refusal("tsplice_aggret")
check "aggregate splice result refused by name",
  aggCode != 0 and aggOut.contains("importjs proc `mk.0") and
    aggOut.contains("aggregate"), aggOut

# The same for a `var`/`lent` string, which is a pointer to the Nim value.
let (spOut, spCode) = refusal("tsplice_strptr")
check "var string splice parameter refused by name",
  spCode != 0 and spOut.contains("parameter `s.0` of `show.0") and
    spOut.contains("pointer to a string"), spOut

echo "tcodegen: all checks passed"
