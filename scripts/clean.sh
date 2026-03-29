#!/bin/sh

# removes old results and copies over the Muncie.p04.tmp.hdf 

# delete old result files
rm Muncie.*

# copy over the run Muncie input files
cp wrk_source/*.* .
