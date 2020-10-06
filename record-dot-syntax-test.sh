#!/usr/bin/env bash

PATH=`pwd`/_build/stage1/bin:$PATH; export PATH
make test TEST=RecordDotSyntax
make test TEST=RecordDotSyntaxFail0
make test TEST=RecordDotSyntaxFail1
make test TEST=RecordDotSyntaxFail2
make test TEST=RecordDotSyntaxFail3
make test TEST=RecordDotSyntaxFail4
