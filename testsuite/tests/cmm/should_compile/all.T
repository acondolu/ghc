#
test('selfloop', [cmm_src], compile, ['-no-hs-main'])
test('T16930', normal, makefile_test, ['T16930'])
test('T17442', normal, compile, [''])
