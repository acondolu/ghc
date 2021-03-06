# Tests for LLVM code generator

def f( name, opts ):
  opts.only_ways = ['optllvm', 'llvm', 'debugllvm']

setTestOpts(f)

# test('T5486', normal, compile, [''])
test('T5681', normal, compile, [''])
test('T6158', [reqlib('vector'), reqlib('primitive')], compile, ['-package vector -package primitive'])
test('T7571', cmm_src, compile, ['-no-hs-main'])
test('T7575', unless(wordsize(32), skip), compile, [''])
test('T8131b', normal, compile, [''])
test('T11649', normal, compile, [''])
test('T17920fail', cmm_src, compile_fail, ['-no-hs-main'])
