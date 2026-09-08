#!/bin/bash

## File: Pterodactyl Arma 3 Image - entrypoint.sh
## Author: David Wolfe (Red-Thirten)
## Contributors: Aussie Server Hosts (https://aussieserverhosts.com/), Stephen White (SilK)
## Fork: Age of Clones - Steam Workshop mod list is pulled from a Strike Launcher
##       workshop.json URL instead of an Arma 3 Launcher modlist.html export.
## Date: 2022/11/26
## License: MIT License

## === CONSTANTS ===
STEAMCMD_DIR="./steamcmd"                       # SteamCMD's directory containing steamcmd.sh
WORKSHOP_DIR="./Steam/steamapps/workshop"       # SteamCMD's directory containing workshop downloads
STEAMCMD_LOG="${STEAMCMD_DIR}/steamcmd.log"     # Log file for SteamCMD
GAME_ID=107410                                  # SteamCMD ID for the Arma 3 GAME (not server). Only used for Workshop mod downloads.
EGG_URL='https://pterodactyleggs.com/egg/6735ff3e4924a4e9bbcb79b0'   # URL for Pterodactyl Egg & Info (only used as info to legacy users)
MOD_JSON_DEFAULT_FILE="workshop.json"           # Default local file name (cache/fallback) for the Workshop mod list JSON
STEAM_API_URL='https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/'   # Steam Web API used to check mods for updates
UPDATE_STAMP_FILE=".workshop_update_time"       # File inside a mod's directory that stores the Workshop update time it was downloaded for

# Color Codes
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

## === ENVIRONMENT VARS ===
# STARTUP, STARTUP_PARAMS, STEAM_USER, STEAM_PASS, SERVER_BINARY, MOD_JSON_URL, MOD_JSON_FILE, MOD_JSON_PRUNE, MOD_FILE, MODIFICATIONS, SERVERMODS, OPTIONALMODS, UPDATE_SERVER, CLEAR_CACHE, VALIDATE_SERVER, MODS_LOWERCASE, STEAMCMD_EXTRA_FLAGS, CDLC, STEAMCMD_APPID, HC_NUM, SERVER_PASSWORD, HC_HIDE, STEAMCMD_ATTEMPTS, BASIC_URL, DISABLE_MOD_UPDATES, STEAMCMD_VERBOSE

## === GLOBAL VARS ===
# validateServer, extraFlags, updateAttempt, modifiedStartup, allMods, CLIENT_MODS, jsonMods, modNames,
# modUpdateTimes, modUnavailable, latestUpdate, localUpdate, steamcmdArgs, steamcmdOutputHidden

## === DEFINE FUNCTIONS ===
#
# Prints the tail of the SteamCMD log, but only if SteamCMD's output was hidden from the console
function PrintSteamCMDLog { #[No input]
    if [[ ${steamcmdOutputHidden} == 1 ]] && [[ -s "${STEAMCMD_LOG}" ]]; then
        echo -e "${YELLOW}Last 25 lines of SteamCMD's hidden output:${NC}"
        tail -n 25 "${STEAMCMD_LOG}"
    fi
}

# Runs SteamCMD with specified variables and performs error handling.
function RunSteamCMD { #[Input: int server=0 mod=1 optional_mod=2; int id]
    # Clear previous SteamCMD log
    if [[ -f "${STEAMCMD_LOG}" ]]; then
        rm -f "${STEAMCMD_LOG:?}"
    fi

    updateAttempt=0
    while (( $updateAttempt < $STEAMCMD_ATTEMPTS )); do # Loop for specified number of attempts
        # Increment attempt counter
        updateAttempt=$((updateAttempt+1))

        if (( $updateAttempt > 1 )); then # Notify if not first attempt
            echo -e "\t${YELLOW}Re-Attempting download/update in 3 seconds...${NC} (Attempt ${CYAN}${updateAttempt}${NC} of ${CYAN}${STEAMCMD_ATTEMPTS}${NC})\n"
            sleep 3
        fi

        # Check if updating server or mod
        if [[ $1 == 0 ]]; then # Server
            steamcmdArgs=(+force_install_dir /home/container "+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" +app_update $2 $extraFlags $validateServer +quit)
        else # Mod
            steamcmdArgs=("+login \"${STEAM_USER}\" \"${STEAM_PASS}\"" +workshop_download_item $GAME_ID $2 +quit)
        fi

        # Mod downloads are logged quietly by default, because SteamCMD repeats its whole login
        # banner for every single mod. The server update always keeps its output, so its download
        # progress stays visible.
        if [[ $1 == 0 ]] || [[ ${STEAMCMD_VERBOSE} == "1" ]]; then
            steamcmdOutputHidden=0
            numactl --physcpubind=+0 ${STEAMCMD_DIR}/steamcmd.sh "${steamcmdArgs[@]}" | tee -a "${STEAMCMD_LOG}"
            steamcmdExitCode=${PIPESTATUS[0]}
        else
            steamcmdOutputHidden=1
            numactl --physcpubind=+0 ${STEAMCMD_DIR}/steamcmd.sh "${steamcmdArgs[@]}" >> "${STEAMCMD_LOG}" 2>&1
            steamcmdExitCode=$?
        fi

        # Error checking for SteamCMD
        # Catch errors (ignore setlocale, SDL, steamservice, thread priority, and libcurl warnings)
        loggedErrors=$(grep -i "error\|failed" "${STEAMCMD_LOG}" | grep -iv "setlocal\|SDL\|steamservice\|thread\|libcurl")
        if [[ -n ${loggedErrors} ]]; then
            # Soft errors
            if [[ -n $(grep -i "Timeout downloading item" "${STEAMCMD_LOG}") ]]; then # Mod download timeout
                echo -e "\n${YELLOW}[UPDATE]: ${NC}Timeout downloading Steam Workshop mod: \"${CYAN}${modName}${NC}\" (${CYAN}${2}${NC})"
                echo -e "\t(This is expected for particularly large mods)"
            elif [[ -n $(grep -i "0x402\|0x6\|0x602" "${STEAMCMD_LOG}") ]]; then # Connection issue with Steam
                echo -e "\n${YELLOW}[UPDATE]: ${NC}Connection issue with Steam servers."
                echo -e "\t(Steam servers may currently be down, or a connection cannot be made reliably)"
            # Hard errors
            elif [[ -n $(grep -i "Password check for AppId" "${STEAMCMD_LOG}") ]]; then # Incorrect beta branch password
                echo -e "\n${RED}[UPDATE]: ${YELLOW}Incorrect password given for beta branch. ${CYAN}Skipping download...${NC}"
                echo -e "\t(Check your \"[ADVANCED] EXTRA FLAGS FOR STEAMCMD\" startup parameter)"
                break
            # Fatal errors
            elif [[ -n $(grep -i "Invalid Password\|two-factor\|No subscription" "${STEAMCMD_LOG}") ]]; then # Wrong username/password, Steam Guard is turned on, or host is using anonymous account
                echo -e "\n${RED}[UPDATE]: Cannot login to Steam - Improperly configured account and/or credentials"
                echo -e "\t${YELLOW}Please contact your administrator/host and give them the following message:${NC}"
                echo -e "\t${CYAN}Your Egg, or your client's server, is not configured with valid Steam credentials.${NC}"
                echo -e "\t${CYAN}Either the username/password is wrong, or Steam Guard is not properly configured"
                echo -e "\t${CYAN}according to this egg's documentation/README.${NC}\n"
                exit 1
            elif [[ -n $(grep -i "Download item" "${STEAMCMD_LOG}") ]]; then # Steam account does not own base game for mod downloads, or unknown
                echo -e "\n${RED}[UPDATE]: Cannot download mod - Download failed"
                echo -e "\t${YELLOW}While unknown, this error is likely due to your host's Steam account not owning the base game.${NC}"
                echo -e "\t${YELLOW}(Please contact your administrator/host if this issue persists)${NC}\n"
                exit 1
            elif [[ -n $(grep -i "0x202\|0x212" "${STEAMCMD_LOG}") ]]; then # Not enough disk space
                echo -e "\n${RED}[UPDATE]: Unable to complete download - Not enough storage"
                echo -e "\t${YELLOW}You have run out of your allotted disk space.${NC}"
                echo -e "\t${YELLOW}Please contact your administrator/host for potential storage upgrades.${NC}\n"
                exit 1
            elif [[ -n $(grep -i "0x606" "${STEAMCMD_LOG}") ]]; then # Disk write failure
                echo -e "\n${RED}[UPDATE]: Unable to complete download - Disk write failure"
                echo -e "\t${YELLOW}This is normally caused by directory permissions issues,"
                echo -e "\t${YELLOW}but could be a more serious hardware issue.${NC}"
                echo -e "\t${YELLOW}(Please contact your administrator/host if this issue persists)${NC}\n"
                exit 1
            else # Unknown caught error
                echo -e "\n${RED}[UPDATE]: ${YELLOW}An unknown error has occurred with SteamCMD. ${CYAN}Skipping download...${NC}"
                echo -e "SteamCMD Errors:\n${loggedErrors}"
                PrintSteamCMDLog
                echo -e "\t${YELLOW}(Please contact your administrator/host if this issue persists)${NC}\n"
                break
            fi
        elif [[ $steamcmdExitCode != 0 ]]; then # Unknown fatal error
            echo -e "\n${RED}[UPDATE]: SteamCMD has crashed for an unknown reason!${NC} (Exit code: ${CYAN}${steamcmdExitCode}${NC})"
            PrintSteamCMDLog
            echo -e "\t${YELLOW}(Please contact your administrator/host for support)${NC}\n"
            cp -r /tmp/dumps /home/container/dumps
            exit $steamcmdExitCode
        else # Success!
            if [[ $1 == 0 ]]; then # Server
                echo -e "\n${GREEN}[UPDATE]: Game server is up to date!${NC}"
            else # Mod
                if [[ ${steamcmdOutputHidden} == 1 ]]; then # Summarize the hidden SteamCMD output in a single line
                    modSize=$(grep -o "([0-9]* bytes)" "${STEAMCMD_LOG}" | tail -1 | grep -o "[0-9]*")
                    if [[ -n ${modSize} ]]; then
                        echo -e "\tDownloaded ${CYAN}$(numfmt --to=iec-i --suffix=B ${modSize} 2> /dev/null || echo ${modSize} bytes)${NC} from the Steam Workshop."
                    fi
                fi
                # Move the downloaded mod to the root directory, and replace existing mod if needed
                mkdir -p ./@$2
                rm -rf ./@$2/*
                mv -f ${WORKSHOP_DIR}/content/$GAME_ID/$2/* ./@$2
                rm -d ${WORKSHOP_DIR}/content/$GAME_ID/$2
                # Make the mods contents all lowercase
                ModsLowercase @$2
                # Move any .bikey's to the keys directory
                echo -e "\tMoving any mod ${CYAN}.bikey${NC} files to the ${CYAN}~/keys/${NC} folder..."
                if [[ $1 == 1 ]]; then
                    find ./@$2 -name "*.bikey" -type f -exec cp {} ./keys \;
                else
                    # Give optional mod keys a custom name which can be checked later for deleting unconfigured mods
                    for file in $(find ./@$2 -name "*.bikey" -type f); do
                        filename=$(basename ${file})

                        cp $file ./keys/optional_$2_${filename}

                    done;

                    echo -e "\tMod with ID $2 is an optional mod. Deleting original mod download folder..."
                    rm -r ./@$2

                    # Recreate a directory so time-based detection of auto updates works correctly
                    mkdir ./@$2_optional
                fi
                # Remember which Workshop update this download corresponds to, so the next update is detected exactly
                if [[ ${latestUpdate} =~ ^[0-9]+$ ]]; then
                    if [[ $1 == 1 ]]; then
                        echo "${latestUpdate}" > ./@$2/${UPDATE_STAMP_FILE}
                    else
                        echo "${latestUpdate}" > ./@$2_optional/${UPDATE_STAMP_FILE}
                    fi
                fi
                echo -e "${GREEN}[UPDATE]: Mod download/update successful!${NC}"
            fi
            break
        fi
        if (( $updateAttempt == $STEAMCMD_ATTEMPTS )); then # Notify if failed last attempt
            if [[ $1 == 0 ]]; then # Server
                echo -e "\t${RED}Final attempt made! ${YELLOW}Unable to complete game server update. ${CYAN}Skipping...${NC}"
                echo -e "\t(Please try again at a later time)"
                sleep 3
            else # Mod
                echo -e "\t${RED}Final attempt made! ${YELLOW}Unable to complete mod download/update. ${CYAN}Skipping...${NC}"
                echo -e "\t(You may try again later, or manually upload this mod to your server via SFTP)"
                sleep 3
            fi
        fi
    done
}

# Takes a directory (string) as input, and recursively makes all files & folders lowercase.
function ModsLowercase {
    echo -e "\n\tMaking mod ${CYAN}$1${NC} files/folders lowercase..."
    for SRC in `find ./$1 -depth`
    do
        DST=`dirname "${SRC}"`/`basename "${SRC}" | tr '[A-Z]' '[a-z]'`
        if [ "${SRC}" != "${DST}" ]
        then
            [ ! -e "${DST}" ] && mv -T "${SRC}" "${DST}"
        fi
    done
}

# Extracts "modID<TAB>modName" lines from a Strike Launcher style Workshop mod list JSON file.
# Uses jq when available, and falls back to a simple grep parser (IDs only) if it is not installed.
function ParseWorkshopJson { #[Input: str file - Output: printf of "modID\tmodName" lines]
    if command -v jq &> /dev/null; then
        jq -r '
            (if type == "array" then .
             elif type == "object" then (.workshopAddons // .addons // .mods // .items // [])
             else [] end)[]
            | if type == "object"
              then ((.id // .publishedFileId // .fileId // empty) | tostring) + "\t" + ((.name // "") | tostring)
              else (. | tostring) + "\t"
              end
        ' "$1" 2> /dev/null | grep -E '^[0-9]+'
    else
        grep -oE '"(id|publishedFileId|fileId)"[[:space:]]*:[[:space:]]*"?[0-9]+"?' "$1" | grep -oE '[0-9]+' | sed -e 's/$/\t/'
    fi
}

# Checks whether a file exists and contains at least one usable Steam Workshop mod ID
function IsValidWorkshopJson { #[Input: str file - Output: exit code]
    [[ -s $1 ]] && [[ -n $(ParseWorkshopJson "$1" | head -1) ]]
}

# Looks up the last update time (and title) of every given mod ID with a single Steam API request,
# and stores them in modUpdateTimes/modNames. Mods that Steam no longer serves land in modUnavailable.
# Requesting the Workshop pages one by one instead gets rate limited by Steam after a handful of
# mods, which silently hides mod updates for the rest of the mod list.
function FetchWorkshopUpdateTimes { #[Input: str space delimited mod IDs]
    local modIDs=($1)
    local postData="itemcount=${#modIDs[@]}"
    local index=0
    local apiResponse apiID apiResult apiTime apiTitle

    if [[ ${#modIDs[@]} == 0 ]] || ! command -v jq &> /dev/null; then
        return
    fi

    for apiID in "${modIDs[@]}"; do
        postData+="&publishedfileids[${index}]=${apiID}"
        index=$((index+1))
    done

    apiResponse=$(curl -s --connect-timeout 15 --max-time 60 -X POST -d "${postData}" "${STEAM_API_URL}")
    while IFS=$'\t' read -r apiID apiResult apiTime apiTitle; do
        [[ $apiID =~ ^[0-9]+$ ]] || continue
        if [[ $apiResult == 1 ]] && [[ $apiTime =~ ^[0-9]+$ ]] && (( apiTime > 0 )); then
            modUpdateTimes[$apiID]=${apiTime}
            if [[ -z ${modNames[$apiID]} ]] && [[ -n $apiTitle ]]; then
                modNames[$apiID]="${apiTitle}"
            fi
        else
            modUnavailable[$apiID]=${apiResult}
        fi
    done < <(echo "${apiResponse}" | jq -r '.response.publishedfiledetails[]? | "\(.publishedfileid)\t\(.result // 0)\t\(.time_updated // 0)\t\(.title // "")"' 2> /dev/null)
}

# Removes duplicate items from a semicolon delimited string
function RemoveDuplicates { #[Input: str - Output: printf of new str]
    if [[ -n $1 ]]; then # If nothing to compare, skip to prevent extra semicolon being returned
        echo $1 | sed -e 's/;/\n/g' | sort -u | xargs printf '%s;'
    fi
}

# === ENTRYPOINT START ===

# Wait for the container to fully initialize
sleep 1

# Set environment variable that holds the Internal Docker IP
INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

# Switch to the container's working directory
cd /home/container || exit 1

# Check for old eggs
if [[ -z ${VALIDATE_SERVER} ]]; then # VALIDATE_SERVER was not in the previous version
    echo -e "\n${RED}[STARTUP_ERR]: Please contact your administrator/host for support, and give them the following message:${NC}\n"
    echo -e "\t${CYAN}Your Arma 3 Egg is outdated and no longer supported.${NC}"
    echo -e "\t${CYAN}Please download the latest version at the following link, and install it in your panel:${NC}"
    echo -e "\t${CYAN}${EGG_URL}${NC}\n"
    exit 1
fi

# Collect and parse all specified mods
if [[ -n ${MODIFICATIONS} ]] && [[ ${MODIFICATIONS} != *\; ]]; then # Add manually specified mods to the client-side mods list, while checking for trailing semicolon
    CLIENT_MODS="${MODIFICATIONS};"
else
    CLIENT_MODS=${MODIFICATIONS}
fi
# Download the Steam Workshop mod list JSON (Strike Launcher format), and add its mods to the client-side mods list
MOD_JSON_FILE=${MOD_JSON_FILE:-$MOD_JSON_DEFAULT_FILE}
declare -A modNames
declare -A modUpdateTimes
declare -A modUnavailable
jsonModCount=0
if [[ -n ${MOD_JSON_URL} ]]; then
    echo -e "\n${GREEN}[STARTUP]: ${NC}Fetching the Steam Workshop mod list from: ${CYAN}${MOD_JSON_URL}${NC}"
    if ! command -v jq &> /dev/null; then
        echo -e "\t${YELLOW}(jq is not installed in this image - using the built-in fallback parser)${NC}"
    fi
    tmpJson=$(mktemp)
    httpCode=$(curl -sL --connect-timeout 15 --max-time 120 -w '%{http_code}' -o "${tmpJson}" "${MOD_JSON_URL}")
    if [[ ${httpCode} == 2* ]] && IsValidWorkshopJson "${tmpJson}"; then
        mv -f "${tmpJson}" "${MOD_JSON_FILE}"
        echo -e "\t${GREEN}Mod list downloaded successfully.${NC} (Saved as \"${CYAN}${MOD_JSON_FILE}${NC}\")"
    else
        rm -f "${tmpJson}"
        echo -e "\n${YELLOW}[STARTUP_WARN]: Could not download a valid mod list from the given URL!${NC} (HTTP status: ${CYAN}${httpCode:-none}${NC})"
        echo -e "\tCheck your \"${CYAN}Workshop Mod List JSON URL${NC}\" startup variable, and that the web server is reachable."
        if [[ -f ${MOD_JSON_FILE} ]]; then
            echo -e "\t${CYAN}Falling back to the last downloaded mod list...${NC}"
        fi
    fi
fi
if [[ -f ${MOD_JSON_FILE} ]] && IsValidWorkshopJson "${MOD_JSON_FILE}"; then # Parse the mod list, and remember each mod's name for nicer update messages
    while IFS=$'\t' read -r jsonModID jsonModName; do
        [[ $jsonModID =~ ^[0-9]+$ ]] || continue
        jsonMods+="@${jsonModID};"
        jsonModCount=$((jsonModCount+1))
        if [[ -n $jsonModName ]]; then
            modNames[$jsonModID]="${jsonModName}"
        fi
    done < <(ParseWorkshopJson "${MOD_JSON_FILE}")
    CLIENT_MODS+=${jsonMods}
    echo -e "\t${GREEN}${jsonModCount} Steam Workshop mod(s)${NC} loaded from \"${CYAN}${MOD_JSON_FILE}${NC}\"."
elif [[ -n ${MOD_JSON_URL} ]] || [[ -f ${MOD_JSON_FILE} ]]; then # Only warn if a mod list was actually expected
    echo -e "\n${YELLOW}[STARTUP_WARN]: No valid Steam Workshop mod list JSON is available!${NC}"
    echo -e "\tExpected format: ${CYAN}{\"workshopAddons\": [{\"id\": \"463939057\", \"name\": \"ace\"}]}${NC}"
    if [[ -n "${CLIENT_MODS}" ]] || [[ -f "${MOD_FILE}" ]]; then
        echo -e "\t${CYAN}Reverting to the manually configured mods...${NC}"
    fi
fi

if [[ -f ${MOD_FILE} ]] && [[ -n "$(cat ${MOD_FILE} | grep 'Created by Arma 3 Launcher')" ]]; then # If the mod list file exists and is valid, parse and add mods to the client-side mods list
    CLIENT_MODS+=$(cat ${MOD_FILE} | grep 'id=' | cut -d'=' -f3 | cut -d'"' -f1 | xargs printf '@%s;')
elif [[ -n "${MOD_FILE}" ]]; then # If MOD_FILE is not null, warn user file is missing or invalid
    echo -e "\n${YELLOW}[STARTUP_WARN]: Arma 3 Modlist file \"${CYAN}${MOD_FILE}${YELLOW}\" could not be found, or is invalid!${NC}"
    echo -e "\tEnsure your uploaded modlist's file name matches your Startup Parameter."
    echo -e "\tOnly files exported from an Arma 3 Launcher are permitted."
    if [[ -n "${CLIENT_MODS}" ]]; then
        echo -e "\t${CYAN}Reverting to the manual mod list...${NC}"
    fi
fi
if [[ -n ${SERVERMODS} ]] && [[ ${SERVERMODS} != *\; ]]; then # Add server mods to the master mods list, while checking for trailing semicolon
    allMods="${SERVERMODS};"
else
    allMods=${SERVERMODS}
fi
if [[ -n ${OPTIONALMODS} ]] && [[ ${OPTIONALMODS} != *\; ]]; then # Add specified optional mods to the mods list, while checking for trailing semicolon
    allMods+="${OPTIONALMODS};"
else
    allMods+=${OPTIONALMODS}
fi
allMods+=$CLIENT_MODS # Add all client-side mods to the master mod list
CLIENT_MODS=$(RemoveDuplicates ${CLIENT_MODS}) # Remove duplicate mods from CLIENT_MODS, if present
allMods=$(RemoveDuplicates ${allMods}) # Remove duplicate mods from allMods, if present
allMods=$(echo $allMods | sed -e 's/;/ /g') # Convert from string to array

# Update everything (server and mods), if specified
if [[ ${UPDATE_SERVER} == 1 ]]; then
    echo -e "\n${GREEN}[STARTUP]: ${CYAN}Starting checks for all updates...${NC}"
    echo -e "(It is okay to ignore any \"SDL\", \"steamservice\", and \"thread priority\" errors during this process)\n"

    ## Update game server
    echo -e "${GREEN}[UPDATE]:${NC} Checking for game server updates with App ID: ${CYAN}${STEAMCMD_APPID}${NC}..."

    if [[ ${VALIDATE_SERVER} == 1 ]]; then # Validate will be added as a parameter if specified
        echo -e "\t${CYAN}File validation enabled.${NC} (This may take extra time to complete)"
        validateServer="validate"
    else
        validateServer=""
    fi

    # Determine what extra flags should be set
    if [[ -n ${STEAMCMD_EXTRA_FLAGS} ]]; then
        echo -e "\t(${YELLOW}Advanced${NC}) Extra SteamCMD flags specified: ${CYAN}${STEAMCMD_EXTRA_FLAGS}${NC}\n"
        extraFlags=${STEAMCMD_EXTRA_FLAGS}
    elif [[ ${CDLC} == 1 ]]; then
        echo -e "\t${CYAN}Download/Update Creator DLC server files enabled.${NC}\n"
        extraFlags="-beta creatordlc"
    else
        echo -e ""
        extraFlags=""
    fi

    RunSteamCMD 0 ${STEAMCMD_APPID}

    ## Update mods
    if [[ -n $allMods ]] && [[ ${DISABLE_MOD_UPDATES} != 1 ]]; then
        echo -e "\n${GREEN}[UPDATE]:${NC} Checking all ${CYAN}Steam Workshop mods${NC} for updates..."
        if [[ ${STEAMCMD_VERBOSE} != "1" ]]; then
            echo -e "\t(SteamCMD's output is hidden for mod downloads. It is printed automatically on errors,"
            echo -e "\t and can be shown for every mod with the \"${CYAN}Verbose SteamCMD Mod Output${NC}\" startup variable)"
        fi
        # Look up every mod's last update time in one request, instead of scraping one page per mod
        FetchWorkshopUpdateTimes "$(echo ${allMods} | sed -e 's/@//g' | tr ' ' '\n' | grep -E '^[0-9]+$' | tr '\n' ' ')"
        if [[ ${#modUpdateTimes[@]} -gt 0 ]]; then
            echo -e "\t${GREEN}${#modUpdateTimes[@]} mod(s)${NC} checked against the Steam Workshop API."
        else
            echo -e "\t${YELLOW}The Steam Workshop API could not be reached - falling back to the Workshop pages.${NC}"
            echo -e "\t(Steam rate limits those, so mod updates may go unnoticed)"
        fi

        for modID in $(echo $allMods | sed -e 's/@//g')
        do
            if [[ $modID =~ ^[0-9]+$ ]]; then # Only check mods that are in ID-form
                # If a mod is defined in OPTIONALMODS, and is not defined in CLIENT_MODS or SERVERMODS, then treat as an optional mod
                # Optional mods are given a different directory which is checked to see if a new update is available. This is to ensure
                # if an optional mod is switched to be a standard client-side mod, this script will redownload the mod
                if [[ "${OPTIONALMODS}" == *"@${modID};"* ]] && [[ "${CLIENT_MODS}" != *"@${modID};"* ]] && [[ "${SERVERMODS}" != *"@${modID};"* ]]; then
                    modType=2
                    modDir=@${modID}_optional
                else
                    modType=1
                    modDir=@${modID}
                fi

                # Get the mod's latest update in epoch time, and fall back to its Steam Workshop changelog page
                latestUpdate=${modUpdateTimes[$modID]}
                if [[ -z ${latestUpdate} ]] && [[ -z ${modUnavailable[$modID]} ]]; then
                    latestUpdate=$(curl -sL https://steamcommunity.com/sharedfiles/filedetails/changelog/$modID | grep '<p id=' | head -1 | cut -d'"' -f2)
                fi

                # Get the Workshop update time the local copy was downloaded for
                localUpdate=0
                if [[ -d ${modDir} ]]; then
                    localUpdate=$(cat "${modDir}/${UPDATE_STAMP_FILE}" 2> /dev/null)
                    if [[ ! ${localUpdate} =~ ^[0-9]+$ ]]; then # Mods that were downloaded before update times were tracked
                        localUpdate=$(find ${modDir} | head -1 | xargs stat -c%Y)
                    fi
                    if [[ ! ${localUpdate} =~ ^[0-9]+$ ]]; then
                        localUpdate=0
                    fi
                fi

                # If the update time is valid and newer than the local copy's, or the mod hasn't been downloaded yet, download the mod
                if [[ ! -d $modDir ]] || [[ ( ${latestUpdate} =~ ^[0-9]+$ ) && ( ${latestUpdate} -gt ${localUpdate} ) ]]; then
                    # Get the mod's name from the Workshop page as well
                    modName=${modNames[$modID]}
                    if [[ -z $modName ]]; then # Fall back to the Workshop page if the mod is not named in the mod list JSON
                        modName=$(curl -sL https://steamcommunity.com/sharedfiles/filedetails/changelog/$modID | grep 'workshopItemTitle' | cut -d'>' -f2 | cut -d'<' -f1)
                    fi
                    if [[ -z $modName ]]; then # Set default name if unavailable
                        modName="[NAME UNAVAILABLE]"
                    fi
                    if [[ ! -d $modDir ]]; then
                        echo -e "\n${GREEN}[UPDATE]:${NC} Downloading new Mod: \"${CYAN}${modName}${NC}\" (${CYAN}${modID}${NC})"
                    else
                        echo -e "\n${GREEN}[UPDATE]:${NC} Mod update found for: \"${CYAN}${modName}${NC}\" (${CYAN}${modID}${NC})"
                    fi
                    if [[ -n $latestUpdate ]] && [[ $latestUpdate =~ ^[0-9]+$ ]]; then # Notify last update date, if valid
                        echo -e "\tMod was last updated: ${CYAN}$(date -d @${latestUpdate})${NC}"
                    fi

                    # Delete SteamCMD appworkshop cache before running to avoid mod download failures
                    echo -e "\tClearing SteamCMD appworkshop cache..."
                    rm -f ${WORKSHOP_DIR}/appworkshop_$GAME_ID.acf

                    echo -e "\tAttempting mod update/download via SteamCMD...\n"
                    RunSteamCMD $modType $modID
                elif [[ ! ${latestUpdate} =~ ^[0-9]+$ ]]; then # The mod cannot be checked for updates at all
                    if [[ -n ${modUnavailable[$modID]} ]]; then
                        echo -e "\n${YELLOW}[UPDATE]:${NC} Mod ${CYAN}${modID}${NC} is no longer available on the Steam Workshop. (API result: ${CYAN}${modUnavailable[$modID]}${NC})"
                        echo -e "\t(It was removed or made private. Any local copy is kept and still loaded)"
                    else
                        echo -e "\n${YELLOW}[UPDATE]:${NC} Could not determine the last update time of mod ${CYAN}${modID}${NC}. ${CYAN}Skipping...${NC}"
                    fi
                fi
            fi
        done

        # Check over key files for unconfigured optional mods' .bikey files
        for keyFile in $(find ./keys -name "*.bikey" -type f); do
            keyFileName=$(basename ${keyFile})

            # If the key file is using the optional mod file name
            if [[ "${keyFileName}" == "optional_"* ]]; then
                modID=$(echo "${keyFileName}" | cut -d _ -f 2)

                # If mod is not in optional mods, delete it
                # If a mod is configured in CLIENT_MODS or SERVERMODS, we should still delete this file
                # as a new file will have been copied that does not follow the naming scheme
                if [[ "${OPTIONALMODS}" != *"@${modID};"* ]]; then

                    # We only need to let the user know the key file is being deleted if this mod is no longer configured at all.
                    # If CLIENT_MODS contains the mod ID, we'd just confuse the user by telling them we are deleting the optional .bikey file
                    if [[ "${CLIENT_MODS}" != *"@${modID};"* ]]; then
                        echo -e "\tKey file and directory for unconfigured optional mod ${CYAN}${modID}${NC} is being deleted..."
                    fi

                    # Delete the optional mod .bikey file and directory
                    rm ${keyFile}
                    rmdir ./@${modID}_optional 2> /dev/null
                fi
            fi
        done;

        # Delete downloaded Workshop mods that are no longer part of the mod list, if specified
        if [[ ${MOD_JSON_PRUNE} == "1" ]]; then
            if [[ ${jsonModCount} -gt 0 ]]; then
                echo -e "\n${GREEN}[UPDATE]:${NC} Checking for ${CYAN}removed mods${NC} to clean up..."
                for modDir in ./@[0-9]*; do
                    [[ -d ${modDir} ]] || continue
                    modID=$(basename ${modDir} | sed -e 's/^@//' -e 's/_optional$//')
                    [[ $modID =~ ^[0-9]+$ ]] || continue
                    if [[ " ${allMods} " != *" @${modID} "* ]]; then
                        echo -e "\tMod ${CYAN}${modID}${NC} is no longer in the mod list. Deleting its files and keys..."
                        for keyFile in $(find ${modDir} -name "*.bikey" -type f); do
                            rm -f "./keys/$(basename ${keyFile})"
                        done
                        rm -f ./keys/optional_${modID}_*.bikey
                        rm -rf ${modDir}
                    fi
                done
            else
                echo -e "\n${YELLOW}[UPDATE]:${NC} Skipping the cleanup of removed mods, because no mod list JSON was loaded."
                echo -e "\t(This protects your installed mods from being deleted when the mod list URL is unreachable)"
            fi
        fi

        echo -e "${GREEN}[UPDATE]:${NC} Steam Workshop mod update check ${GREEN}complete${NC}!"
    fi
fi

# Check if specified server binary exists.
if [[ ! -f ./${SERVER_BINARY} ]]; then
    echo -e "\n${RED}[STARTUP_ERR]: Specified Arma 3 server binary could not be found in the root directory!${NC}"
    echo -e "${YELLOW}Please do the following to resolve this issue:${NC}"
    echo -e "\t${CYAN}- Double check your \"Server Binary\" Startup Variable is correct.${NC}"
    echo -e "\t${CYAN}- Ensure your server has properly installed/updated without errors (reinstalling/updating again may help).${NC}"
    echo -e "\t${CYAN}- Use the File Manager to check that your specified server binary file is not missing from the root directory.${NC}\n"
    exit 1
fi

# Make mods lowercase, if specified
if [[ ${MODS_LOWERCASE} == "1" ]]; then
    for modDir in $allMods
    do
        ModsLowercase $modDir
    done
fi

# Define the log file path with a timestamp
LOG_FILE="/home/container/serverprofile/rpt/arma3server_$(date '+%m_%d_%Y_%H%M%S').rpt"

# Ensure the logs directory exists
mkdir -p /home/container/serverprofile/rpt

# Clear HC cache, if specified
if [[ ${CLEAR_CACHE} == "1" ]]; then
    echo -e "\n${GREEN}[STARTUP]: ${CYAN}Clearing Headless Client profiles cache...${NC}"
    for profileDir in ./serverprofile/home/*
    do
        [ "$profileDir" = "./serverprofile/home/Player" ] && continue
        rm -rf $profileDir
    done
fi

# Check if basic.cfg exists, and download if not (Arma really doesn't like it missing for some reason)
if [[ ! -f ./basic.cfg ]]; then
    echo -e "\n${YELLOW}[STARTUP_WARN]: Basic Network Configuration file \"${CYAN}basic.cfg${YELLOW}\" is missing!${NC}"
    echo -e "\t${YELLOW}Downloading default file for use instead...${NC}"
    curl -sSL ${BASIC_URL} -o ./basic.cfg
fi

# Setup NSS Wrapper for use ($NSS_WRAPPER_PASSWD and $NSS_WRAPPER_GROUP have been set by the Dockerfile)
export USER_ID=$(id -u)
export GROUP_ID=$(id -g)
envsubst < /passwd.template > ${NSS_WRAPPER_PASSWD}

if [[ ${SERVER_BINARY} == *"x64"* ]]; then # Check which libnss-wrapper architecture to run, based off the server binary name
    export LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libnss_wrapper.so
else
    export LD_PRELOAD=/usr/lib/i386-linux-gnu/libnss_wrapper.so
fi

# Replace Startup Variables
modifiedStartup=`eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g')`

# Start Headless Clients if applicable
if [[ ${HC_NUM} > 0 ]]; then
    echo -e "\n${GREEN}[STARTUP]:${NC} Starting ${CYAN}${HC_NUM}${NC} Headless Client(s)."
    for i in $(seq ${HC_NUM})
    do
        if [[ ${HC_HIDE} == "1" ]];
        then
            ./${SERVER_BINARY} -client -connect=127.0.0.1 -port=${SERVER_PORT} -password="${SERVER_PASSWORD}" -profiles=./serverprofile -bepath=./battleye -mod="${CLIENT_MODS}" ${STARTUP_PARAMS} > /dev/null 2>&1 &
        else
            ./${SERVER_BINARY} -client -connect=127.0.0.1 -port=${SERVER_PORT} -password="${SERVER_PASSWORD}" -profiles=./serverprofile -bepath=./battleye -mod="${CLIENT_MODS}" ${STARTUP_PARAMS} &
        fi
        echo -e "${GREEN}[STARTUP]:${CYAN} Headless Client $i${NC} launched."
    done
fi

# Start the Server
echo -e "\n${GREEN}[STARTUP]:${NC} Starting server with the following startup command:"
echo -e "${CYAN}${modifiedStartup}${NC}\n"
if [[ "$STARTUP_PARAMS" == *"-noLogs"* ]]; then
	${modifiedStartup}
else
    ${modifiedStartup} 2>&1 | tee -a "$LOG_FILE"
fi

if [ $? -ne 0 ]; then
    echo -e "\n${RED}PTDL_CONTAINER_ERR: There was an error while attempting to run the start command.${NC}\n"
    exit 1
fi
