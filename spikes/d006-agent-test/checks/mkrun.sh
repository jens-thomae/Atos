#!/bin/bash
# mkrun.sh <iced|slint> <n>: writes build.sh for the run dir
n=$1$2; d=$HOME/agent-test/$n
cat > $d/build.sh <<EOF
#!/bin/bash
# Usage: build.sh [cargo args]   (default: build --release --offline). Logs every build.
cd $d/app || exit 1
export CARGO_NET_OFFLINE=true CARGO_TARGET_DIR=\$HOME/agent-test/target-$1
args=("\$@"); [ \${#args[@]} -eq 0 ] && args=(build --release)
echo "=== \$(date +%T) cargo \${args[*]} --offline" >> $d/build.log
cargo "\${args[@]}" --offline 2>&1 | tee -a $d/build.log
exit \${PIPESTATUS[0]}
EOF
chmod +x $d/build.sh; : > $d/build.log
