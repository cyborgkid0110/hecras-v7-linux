'''
Created on Mar 29, 2019

@author: scott
'''
# This program copies the contents of the plan HDF file produced with an Unsteady
# flow compute, without the Results data group.  This provides the 
# *.p01.tmp.hdf file needed for an Unsteady flow run with the rasUnsteady64 program.
#
# updated 22 Jan 2024 to also remove data groups associated with sediment transport
# result computes
#
# To use from Windows,
# C>python remove_HDF5_Results.py myras_system.p01.hdf
#
# Output is myras_system.p01.tmp.hdf
#
import h5py
import sys
from shutil import copyfile
import os

filename = sys.argv[1]

fsource = h5py.File(filename, 'r')
fdest = h5py.File(os.path.splitext(filename)[0] + '.tmp.hdf', 'w')

# copy attributes
for fattr in  fsource.attrs.keys() :
	fdest.attrs[fattr]= fsource.attrs.get(fattr)
		
# copy groups, except Results and sediment results
for fg in  fsource.keys() :
	if fg == "Results" or fg == "Bed Time Series" or \
		fg == "DSS Time Series" or fg == "Transport Time Series" or \
		fg == "Unsteady Time Series" :
			continue
	else :
		fsource.copy( fg, fdest )
		
fdest.close()
fsource.close()

