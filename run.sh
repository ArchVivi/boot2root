#!/bin/bash

set -e

BOOT_IMG="boot.img"
AIK_DIR="AIK-Linux-mirror"
SDAT2IMG_DIR="sdat2img"
BOOT2ROOT_DIR="boot2root"
WORK_DIR="work"
PARTITIONS="system"

read_prop() {
    local prop_file="$1"
    local prop_key="$2"
    grep "^${prop_key}=" "$prop_file" 2>/dev/null | cut -d'=' -f2-
}

prop_exists() {
    local prop_file="$1"
    local prop_key="$2"
    grep -q "^${prop_key}=" "$prop_file" 2>/dev/null
}

update_prop() {
    local prop_file="$1"
    local prop_key="$2"
    local prop_value="$3"

    if prop_exists "$prop_file" "$prop_key"; then
        sed -i "s|^${prop_key}=.*|${prop_key}=${prop_value}|" "$prop_file"
    else
        echo "${prop_key}=${prop_value}" >> "$prop_file"
    fi
}

remove_service() {
    local rc_file="$1"
    local svc_name="$2"

    [ -f "$rc_file" ] || return 0
    grep -q "^service[[:space:]]\+${svc_name}[[:space:]]" "$rc_file" || return 0

    awk -v svc="$svc_name" '
        /^service[ \t]/ && $2 == svc { skip = 1; next }
        skip && /^([ \t]|$)/ { next }
        { skip = 0; print }
    ' "$rc_file" > "${rc_file}.new" && mv "${rc_file}.new" "$rc_file"
}

patch_fstab() {
    local fstab_file="$1"

    [ -f "$fstab_file" ] || return 0
    grep -q "verify" "$fstab_file" || return 0

    awk '
        /^[ \t]*#/ || NF != 5 { print; next }
        {
            n = split($5, flags, ",")
            out = ""
            for (i = 1; i <= n; i++) {
                if (flags[i] == "verify" || flags[i] == "verifyatboot") continue
                if (flags[i] ~ /^verify=/) continue
                out = (out == "" ? flags[i] : out "," flags[i])
            }
            if (out == "") out = "defaults"
            if (out != $5) sub(/[^ \t]+$/, out)
            print
        }
    ' "$fstab_file" > "${fstab_file}.new" && mv "${fstab_file}.new" "$fstab_file"

    chmod 644 "$fstab_file"
}

find_pattern() {
    local file="$1"
    local pattern="$2"
    local offsets

    offsets=$(LC_ALL=C grep -aboF "$(LC_ALL=C printf "$pattern")" "$file" | cut -d: -f1 | grep -x '[0-9]*')

    if [ "$(echo "$offsets" | grep -c .)" -ne 1 ]; then
        echo "Error: adbd pattern $pattern did not match exactly once"
        exit 1
    fi

    echo "$offsets"
}

read_bytes() {
    local file="$1"
    local offset="$2"
    local count="$3"
    dd if="$file" bs=1 skip="$offset" count="$count" 2>/dev/null | xxd -p
}

adbd_patch() {
    local file="$1"
    local out="$2"
    local offset="$3"
    local after="$4"

    echo "$offset $(read_bytes "$file" "$offset" $((${#after} / 2))) $after" >> "$out"
}

adbd_patches() {
    local file="$1"
    local out="$2"
    local offset

    offset=$(find_pattern "$file" '\xb0\xf1\xff\x3f\x09\xdd\x41\x46\x2a\x46\x06\x46')

    if [ "$(read_bytes "$file" $((offset + 16)) 8)" != "b0f1ff3f06dd0125" ]; then
        echo "Error: local adb second site does not follow anchor"
        exit 1
    fi

    adbd_patch "$file" "$out" $((offset + 5)) e0
    adbd_patch "$file" "$out" $((offset + 22)) 00
    echo "  local adb check disabled at $offset"

    offset=$(find_pattern "$file" '\x4a\xea\x07\x05\xc0\x07\x02\xd0\x18\x98')

    adbd_patch "$file" "$out" "$offset" 002500bf
    echo "  root shell forced at $offset"
}

fs_extract() {
    local img="$1"
    local path="$2"
    local dest="$3"
    rm -f "$dest"
    debugfs -R "dump $path $dest" "$img" 2>/dev/null
    [ -s "$dest" ] || { echo "Error: could not read $path"; exit 1; }
}

create_zip() {
    local name="$1"
    local dir="$2"

    cp "$BOOT2ROOT_DIR/bin/update-binary" "$dir/META-INF/com/google/android/"
    echo "# Dummy" > "$dir/META-INF/com/google/android/updater-script"

    rm -f "${name}.zip"
    (cd "$dir" && zip -r -1 "$OLDPWD/${name}.zip" . > /dev/null)

    echo "Successfully created ${name}.zip"
}

patch_ramdisk() {
    echo "Unpacking boot image"
    cd "$AIK_DIR"
    ./unpackimg.sh "../$BOOT_IMG" > /dev/null 2>&1

    sudo chown -R $USER ramdisk

    echo "Installing binaries"
    mkdir -p ramdisk/sbin
    cp "../$BOOT2ROOT_DIR/bin/adbd" ramdisk/sbin/
    cp "../$BOOT2ROOT_DIR/bin/init.fosflags.sh" ramdisk/
    chmod 755 ramdisk/sbin/adbd ramdisk/init.fosflags.sh

    echo "Patching properties"
    update_prop "ramdisk/default.prop" "ro.adb.secure" "0"
    update_prop "ramdisk/default.prop" "ro.secure" "0"
    update_prop "ramdisk/default.prop" "ro.debuggable" "1"
    update_prop "ramdisk/default.prop" "persist.sys.usb.config" "mtp,adb"

    echo "Removing recovery restore service"
    remove_service "ramdisk/init.aosp.rc" "flash_recovery"

    echo "Disabling dm-verity"
    for FSTAB in ramdisk/fstab.*; do
        [ -f "$FSTAB" ] || continue
        if grep -q "verify" "$FSTAB"; then
            echo "  $(basename "$FSTAB")"
            patch_fstab "$FSTAB"
        fi
    done

    if [ -f "ramdisk/sepolicy" ]; then
        echo "Patching SELinux policy"
        chmod +x "../$BOOT2ROOT_DIR/tools/sepolicy-inject"
        "../$BOOT2ROOT_DIR/tools/sepolicy-inject" -Z adbd -P ramdisk/sepolicy -o ramdisk/sepolicy 2>/dev/null
        "../$BOOT2ROOT_DIR/tools/sepolicy-inject" -s adbd -t adbd -c process -p setcurrent -P ramdisk/sepolicy -o ramdisk/sepolicy 2>/dev/null
        "../$BOOT2ROOT_DIR/tools/sepolicy-inject" -s adbd -t su -c process -p transition -P ramdisk/sepolicy -o ramdisk/sepolicy 2>/dev/null
        "../$BOOT2ROOT_DIR/tools/sepolicy-inject" -s su -t su -c process -p setcurrent -P ramdisk/sepolicy -o ramdisk/sepolicy 2>/dev/null
    fi

    FINGERPRINT=$(read_prop "ramdisk/default.prop" "ro.bootimage.build.fingerprint")

    if [ -n "$FINGERPRINT" ]; then
        MODEL=$(echo "$FINGERPRINT" | cut -d'/' -f2)
        BUILD_INFO=$(echo "$FINGERPRINT" | cut -d'/' -f4 | cut -d':' -f1)
        OUTPUT_NAME="boot-${MODEL}-${BUILD_INFO}"
        OUTPUT_NAME=$(echo "$OUTPUT_NAME" | tr '/:' '__' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
        echo "Device: $MODEL ($BUILD_INFO)"
    else
        OUTPUT_NAME="boot-patched"
    fi

    echo "Repacking boot image"
    ./repackimg.sh > /dev/null 2>&1

    cd ..

    echo "Creating flashable ZIP"
    ZIP_DIR="$WORK_DIR/flashable"
    mkdir -p "$ZIP_DIR/META-INF/com/google/android"

    mv "$AIK_DIR/image-new.img" "$ZIP_DIR/boot.img"

    create_zip "$OUTPUT_NAME" "$ZIP_DIR"
}

patch_dynamic_partitions() {
    echo "Unpacking images"
    for p in $PARTITIONS; do
        brotli -d -f -o "$WORK_DIR/$p.new.dat" "$p.new.dat.br"
        python3 "$SDAT2IMG_DIR/sdat2img.py" "$p.transfer.list" "$WORK_DIR/$p.new.dat" "$WORK_DIR/$p.img" > /dev/null
        rm -f "$WORK_DIR/$p.new.dat"
    done

    PATCH_DIR="$WORK_DIR/flashable/patch"
    mkdir -p "$PATCH_DIR" "$WORK_DIR/flashable/META-INF/com/google/android"

    echo "Patching adbd"
    fs_extract "$WORK_DIR/system.img" /system/apex/com.android.adbd/bin/adbd "$WORK_DIR/adbd"
    adbd_patches "$WORK_DIR/adbd" "$PATCH_DIR/adbd.patch"

    echo "Neutering OTA updates"
    fs_extract "$WORK_DIR/system.img" /system/build.prop "$WORK_DIR/build.prop"
    OTA_VERSION=$(read_prop "$WORK_DIR/build.prop" "ro.build.version.number")
    OTA_VERSION=$((10#$OTA_VERSION))
    echo "ro.build.version.number=$(((1 << 52) | (OTA_VERSION & 1048575)))" > "$PATCH_DIR/build.prop.patch"
    echo "  $OTA_VERSION -> $(cut -d= -f2 "$PATCH_DIR/build.prop.patch")"

    echo "Installing SELinux policy patcher"
    cp "$BOOT2ROOT_DIR/bin/magiskpolicy32" "$PATCH_DIR/"
    cp "$BOOT2ROOT_DIR/bin/magiskpolicy64" "$PATCH_DIR/"
    cp "$BOOT2ROOT_DIR/bin/sepolicy.rules" "$PATCH_DIR/"

    DESCRIPTION=$(read_prop ota.prop "description")

    if [ -n "$DESCRIPTION" ]; then
        MODEL=$(echo "$DESCRIPTION" | cut -d'/' -f2)
        BUILD_INFO=$(echo "$DESCRIPTION" | cut -d'/' -f4 | cut -d':' -f1)
        OUTPUT_NAME="system-${MODEL}-${BUILD_INFO}"
        OUTPUT_NAME=$(echo "$OUTPUT_NAME" | tr '/:' '__' | sed 's/__*/_/g' | sed 's/^_//;s/_$//')
        echo "Device: $MODEL ($BUILD_INFO)"
    else
        OUTPUT_NAME="system-patched"
    fi

    echo "Creating flashable ZIP"
    create_zip "$OUTPUT_NAME" "$WORK_DIR/flashable"
}

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

if [ -f "dynamic_partitions_op_list" ]; then
    echo "Detected FireOS 8 (dynamic partitions)"
    patch_dynamic_partitions
elif [ -f "$BOOT_IMG" ]; then
    echo "Detected FireOS 6 (ramdisk)"
    patch_ramdisk
else
    echo "Error: no $BOOT_IMG and no dynamic_partitions_op_list found"
    exit 1
fi

rm -rf "$WORK_DIR"
