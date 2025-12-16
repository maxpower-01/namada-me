# https://github.com/ekhvalov/cometprune
# https://docs.namada.net/operators/ledger/pruning-cometbft-blocks
# CPU: AMD Ryzen 5 3600 6-Core; Disk: MZVL2512HCJQ-00B00
# Observed runtime: ~12 minutes in this run.
# Pruning result: removed 4,681,008 state entries and 4,681,008 blocks (then compacted).
# Disk usage impact (CometBFT data folder): .../cometbft/data dropped from 201G to 1.1G.

# Install Go (needed to build cometprune)
apt update && apt install -y golang-go
go version

# Get cometprune source and build the binary
git clone https://github.com/ekhvalov/cometprune.git
cd cometprune
go build -o cometprune .

# CometBFT data path (this is what gets pruned)
COMET_DATA="/root/.local/share/namada/namada.5f5de2dd1b88cba30586420/cometbft/data"

# Folder size and number of files
du -sh "$COMET_DATA"
find "$COMET_DATA" -type f | wc -l

# Stop node, prune, 
systemctl stop namadad
./cometprune --path "$COMET_DATA" --keep-blocks 100 

# Start node again and follow logs
systemctl start namadad && journalctl -u namadad -f --no-hostname -o cat