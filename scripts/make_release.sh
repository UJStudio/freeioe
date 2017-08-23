# !/usr/bin/env sh

SKYNET_PLAT=$1

# Release Skynet
./scripts/release_skynet.sh ~/mycode/skynet $SKYNET_PLAT

echo "--------------------------------------------"
echo "IOT System IN:" $PWD

### Get the version by count the commits
VERSION=`git log --oneline | wc -l | tr -d ' '`

### Generate the revision by last commit
set -- $(git log -1 --format="%ct %h")
R_SECS="$(($1 % 86400))"
R_YDAY="$(date --utc --date="@$1" "+%y.%j")"
REVISION="$(printf 'git-%s.%05d-%s' "$R_YDAY" "$R_SECS" "$2")"

echo 'Version:'$VERSION
echo 'Revision:'$REVISION

#rm __release/* -rf
# Make the release folder
mkdir -p __release/skynet_iot

# Clean up the cramfs folder
#sudo rm -rf __install
rm -rf __install
mkdir __install

# Copy files
git archive HEAD | tar -x -C __install
rm -rf __install/examples
rm -rf __install/scripts

# Echo version
echo $VERSION > __install/version
echo $REVISION >> __install/version

# copy lwf files

# Compile lua files
# ./scripts/compile_lua.sh 

# Release example (modbus)
# Release iot
./scripts/release_app.sh iot $VERSION $REVISION
./scripts/release_app.sh bms $VERSION $REVISION
./scripts/release_app.sh modbus_lua $VERSION $REVISION

# For pre-installed applications
mkdir __install/apps
./scripts/pre_inst.sh iot iot $VERSION

#################################
# Count the file sizes
################################
du __install -sh

###################
##
##################
cd __install
tar czvf ../__release/skynet_iot/$VERSION.tar.gz * > /dev/null
md5sum -b ../__release/skynet_iot/$VERSION.tar.gz > ../__release/skynet_iot/$VERSION.tar.gz.md5
du ../__release/skynet_iot/$VERSION.tar.gz -sh
cat ../__release/skynet_iot/$VERSION.tar.gz.md5
## Copy to latest
cp -f ../__release/skynet_iot/$VERSION.tar.gz ../__release/skynet_iot/latest.tar.gz
cp -f ../__release/skynet_iot/$VERSION.tar.gz.md5 ../__release/skynet_iot/latest.tar.gz.md5
cd - > /dev/null

# Clean up the rootfs files
#sudo rm -rf __install
rm -rf __install

# Done
echo 'May GOD with YOU always!'
