#!/bin/sh
PROD_CMD=$1
STAG_CMD=$2
DIVISION=$3
ENS_VERSION=$4
EG_VERSION=$5

# Create a sequence mart.
# Run on an interactive cluster node with plenty of memory.

DB_TYPE=core
MART_DBNAME=${DIVISION}_sequence_mart_${EG_VERSION}
BIG_MEM=1

# Set variables required by dna_chunks.pl.
eval $($PROD_CMD details env_ENSMART)
export ENSMARTHOST=$ENSMARTHOST
export ENSMARTPORT=$ENSMARTPORT
export ENSMARTUSER=$ENSMARTUSER
export ENSMARTPWD=$ENSMARTPASS
export ENSMARTDRIVER=mysql

# Sequence mart pipeline.
$PROD_CMD <<< "CREATE DATABASE IF NOT EXISTS $MART_DBNAME;"

cd dirname $0

perl division_species.pl \
  $($PROD_CMD details script) \
  -release $ENS_VERSION \
  -division $DIVISION \
> /tmp/dbs.tmp

while read SPECIES; do
  perl dna_chunks.pl \
    $SPECIES \
    $DB_TYPE \
    ${ENS_VERSION}_${EG_VERSION} \
    $MART_DBNAME \
    "$SPECIES" \
    $BIG_MEM
done < /tmp/dbs.tmp

rm /tmp/dbs.tmp

perl generate_sequence_template.pl \
  $($PROD_CMD details script) \
  -seq_mart $MART_DBNAME
  -release $ENS_VERSION

# Copy to staging server.
$STAG_CMD <<< "CREATE DATABASE IF NOT EXISTS $MART_DBNAME;"
$PROD_CMD mysqldump $MART_DBNAME | $STAG_CMD $MART_DBNAME
