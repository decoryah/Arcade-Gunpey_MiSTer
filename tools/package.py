#!/usr/bin/env python3
"""Build the release zip in MiSTer's SD card structure from the repository (the Rabbit core's tools/package.py, after the Mystic Warriors core's):

  _Arcade/Gunpey (Japan).mra                                  the MRA                       (mra/*.mra)
  _Arcade/cores/gunpey_<YYYYMMDD>.rbf                         the core                      (releases/gunpey_<YYYYMMDD>.rbf)

  python3 tools/package.py [YYYYMMDD]        (default: the newest RBF in releases/)

Writes dist/Gunpey_MiSTer_<YYYYMMDD>.zip (dist/ is not in the repository). Unzip it over the root of the SD card. No ROMs are in it:
the MAME 0.289 romset (gunpey.zip) goes to /media/fat/games/mame/.
"""
import glob
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DIST = os.path.join(REPO, 'dist')


def main(argv):
    rbfs = sorted(r for r in glob.glob(os.path.join(REPO, 'releases', 'gunpey_*.rbf')) if re.search(r'gunpey_\d{8}\.rbf$', r))
    if argv:
        rbfs = [r for r in rbfs if r.endswith('gunpey_%s.rbf' % argv[0])]
    if not rbfs:
        print('no releases/gunpey_YYYYMMDD.rbf')
        return 1
    rbf = rbfs[-1]
    date = re.search(r'gunpey_(\d{8})\.rbf$', rbf).group(1)
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, 'Gunpey_MiSTer_%s.zip' % date)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full in sorted(glob.glob(os.path.join(REPO, 'mra', '*.mra'))):
            z.write(full, '_Arcade/' + os.path.basename(full))
        z.write(rbf, '_Arcade/cores/' + os.path.basename(rbf))
    print(out)
    with zipfile.ZipFile(out) as z:
        for n in z.namelist():
            print('  ' + n)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
