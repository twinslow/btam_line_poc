#!/bin/sh
# Build submit-ready 80 column card decks from the JCL skeletons and the
# assembler sources.
#   jcl/BSCPOC.jcl   BSC line, EXCP
#   jcl/BSCPOCB.jcl  BSC line, BTAM
#   jcl/ASYPOC.jcl   async TTY line, EXCP
#   jcl/ASYPOCB.jcl  async TTY line, BTAM
set -e
cd "$(dirname "$0")"
cat jcl/header.jcl  src/BSCPOC.asm  jcl/trailer.jcl  > jcl/BSCPOC.jcl
cat jcl/headerb.jcl src/BSCPOCB.asm jcl/trailerb.jcl > jcl/BSCPOCB.jcl
cat jcl/headera.jcl src/ASYPOC.asm  jcl/trailera.jcl > jcl/ASYPOC.jcl
cat jcl/headerc.jcl src/ASYPOCB.asm jcl/trailerc.jcl > jcl/ASYPOCB.jcl
for f in jcl/BSCPOC.jcl jcl/BSCPOCB.jcl jcl/ASYPOC.jcl jcl/ASYPOCB.jcl; do
    echo "built $f ($(wc -l < "$f") cards)"
    awk -v F="$f" 'length($0)>72 {print "WARNING "F" card "NR" exceeds column 72"}' "$f"
done
