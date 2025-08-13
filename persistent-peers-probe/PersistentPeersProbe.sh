#!/bin/bash

# Set the configuration file's path
configPath="/root/.local/share/namada/shielded-expedition.88f17d1d14/config.toml"

# Check if the configuration file exists
if [[ ! -f "$configPath" ]]; then
    # Display an error message if the file is not found
    echo -e "${lightGrey}$(date '+%Y-%m-%dT%H:%M:%S.%3NZ') ${red}ERROR${noColor} - File not found: $configPath."
    exit 1
fi

# Retrieve the 'persistent_peers' field from the configuration file
peersLine=$(grep '^persistent_peers\s*=' "$configPath")
# Extract the peer addresses and format them for processing
peerAddresses=$(echo $peersLine | sed -e 's/^persistent_peers\s*=\s*"\(.*\)"/\1/' | tr ',' '\n' | cut -d '@' -f2)

# Initialize ANSI color codes for console output
lightGrey='\033[0;37m'
green='\033[0;32m'
yellow='\033[0;33m'
red='\033[0;31m'
noColor='\033[0m' # Code to reset to the default terminal color

# Display the total count of persistent peers found in the configuration
echo -e "${lightGrey}$(date '+%Y-%m-%dT%H:%M:%S.%3NZ') ${green}INFO${noColor} - Total persistent_peers: $(echo "$peerAddresses" | wc -l)"

# Create an associative array to hold performance metrics for each peer
declare -A performanceMetrics

# Iterate over each peer to test connectivity and measure latency
for address in $peerAddresses; do
    # Exclude any peer with the IP address set to 0.0.0.0
    if [[ "$address" == *"0.0.0.0"* ]]; then
        continue
    fi
    
    # Extract the IP and port from the peer address
    ip=${address%:*}
    port=${address##*:}
    
    # Log the connection attempt with a timestamp
    echo -e "${lightGrey}$(date '+%Y-%m-%dT%H:%M:%S.%3NZ') ${green}INFO${noColor} - Connection attempt: $address"
    
    # Measure the latency of the TCP connection
    startTime=$(date +%s.%N)
    if nc -z -w3 "$ip" "$port" 2>/dev/null; then
        endTime=$(date +%s.%N)
        latency=$(echo "$endTime - $startTime" | bc)
        # Store the latency in the performance metrics array
        performanceMetrics["$address"]=$latency
        # Log the successful connection and its latency
        echo -e "${lightGrey}$(date '+%Y-%m-%dT%H:%M:%S.%3NZ') ${green}INFO${noColor} - Connection successful: $address; Latency: ${latency}s"
    else
        # Log a warning for a failed connection attempt
        echo -e "${lightGrey}$(date '+%Y-%m-%dT%H:%M:%S.%3NZ') ${yellow}WARN${noColor} - Connection failed: $address"
    fi
done

# Prepare for sorting the peers by latency
latencyAddressPairs=()
for address in "${!performanceMetrics[@]}"; do
    latency=${performanceMetrics[$address]}
    # Combine the latency and address for sorting
    latencyAddressPairs+=("$latency $address")
done

# Determine the total number of addresses processed
totalAddresses=${#latencyAddressPairs[@]}

# Sort the peers by latency
IFS=$'\n' sortedLatencyAddressPairs=($(sort -n <<<"${latencyAddressPairs[*]}"))
unset IFS

# Calculate the partition sizes for color coding
let "firstPartition = totalAddresses / 3"
let "secondPartition = 2 * totalAddresses / 3"

# Header before the summary
echo -e "\n${lightGrey}$(date '+%Y-%m-%dT%H:%M:%S.%3NZ') ${green}INFO${noColor} - Summary of the best connections based on latency:"
i=0

# Display the sorted list of peers and their latencies
for item in "${sortedLatencyAddressPairs[@]}"; do
    address=${item#* }
    latency=${item%% *}
 
    # Determine the color based on the performance tier
    if (( totalAddresses > 2 )); then
        if (( i < firstPartition )); then
            color=$green
        elif (( i < secondPartition )); then
            color=$yellow
        else
            color=$red
        fi
    else
        color=$noColor
    fi

    # Output the sorted persistent_peers by latency
    echo -e "${color}$address; Latency ${latency}s${noColor}"
    let i++
done

# Extract the full peer entries as an array from the original config
readarray -t originalPeersArray <<< "$(grep '^persistent_peers\s*=' "$configPath" | sed -e 's/^persistent_peers\s*=\s*"\(.*\)"/\1/' | tr ',' '\n')"

# Assuming sortedIps is correctly populated with "IP:Port" sorted by latency
readarray -t sortedIps <<< "$(for pair in "${sortedLatencyAddressPairs[@]}"; do echo "${pair#* }"; done)"

# Initialize the sorted persistent_peers string
sortedPersistentPeers=""

# Loop through each sorted IP:Port
for sortedIp in "${sortedIps[@]}"; do
    # Loop through each original peer entry to find a match
    for peerEntry in "${originalPeersArray[@]}"; do
        # Check if the peer entry contains the sorted IP
        if [[ "$peerEntry" == *"$sortedIp"* ]]; then
            # Extract the ID@IP:Port part from the peerEntry
            idIpPort=$(echo "$peerEntry" | grep -oP 'tcp://\K.*')
            # Append the matched entry to the sortedPersistentPeers string
            sortedPersistentPeers+="tcp://$idIpPort,"
            break # Stop searching once a match is found
        fi
    done
done

# Trim the last comma
sortedPersistentPeers=${sortedPersistentPeers%,}

# Header before the persistent_peers
echo -e "\n${lightGrey}$(date '+%Y-%m-%dT%H:%M:%S.%3NZ') ${green}INFO${noColor} - Generating 'persistent_peers' for config.toml:"

# Output the sorted persistent_peers line
echo "persistent_peers = \"$sortedPersistentPeers\""