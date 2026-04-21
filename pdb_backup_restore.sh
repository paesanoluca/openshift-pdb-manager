#!/bin/bash

# PDB Backup and Restore Script for OpenShift/ROSA
# Skips OpenShift system namespaces
# Backup/Delete limited to PDBs with status.disruptionsAllowed > 0

BACKUP_DIR="./pdb-backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Namespaces to skip
SKIP_NAMESPACES="^(openshift|openshift-.*|kube-.*|default|redhat-.*|rosa-.*)"

is_system_namespace() {
    local ns="$1"
    if [[ "$ns" =~ $SKIP_NAMESPACES ]]; then
        return 0  # true, is system namespace
    fi
    return 1  # false, not system namespace
}

get_user_namespaces() {
    local all_ns=$(oc get namespaces -o jsonpath='{.items[*].metadata.name}')
    local user_ns=""
    
    for ns in $all_ns; do
        if ! is_system_namespace "$ns"; then
            user_ns="$user_ns $ns"
        fi
    done
    
    echo "$user_ns"
}

pdb_allowed_disruptions() {
    local pdb="$1"
    local ns="$2"

    local allowed
    allowed=$(oc get pdb "$pdb" -n "$ns" \
        -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)

    [[ -n "$allowed" && "$allowed" -eq 0 ]]
}

backup_pdbs() {
    local namespace="${1:-all}"
    local backup_path="${BACKUP_DIR}/${TIMESTAMP}"
    
    mkdir -p "$backup_path"
    
    if [[ "$namespace" == "all" ]]; then
        echo "Backing up PDBs from user namespaces (skipping system namespaces)..."
        namespaces=$(get_user_namespaces)
    else
        if is_system_namespace "$namespace"; then
            echo "Warning: $namespace is a system namespace. Use --include-system to include it."
            return 1
        fi
        namespaces="$namespace"
    fi
    
    for ns in $namespaces; do
        pdbs=$(oc get pdb -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -n "$pdbs" ]]; then
            mkdir -p "$backup_path/$ns"
            for pdb in $pdbs; do
                if pdb_allowed_disruptions "$pdb" "$ns"; then
                    pods=$(oc get pdb "$pdb" -n "$ns" \
                        -o jsonpath='{.status.expectedPods}' 2>/dev/null)
                    if [[ "$pods" -eq 1 ]]; then
                        echo "WARNING: PDB $pdb in namespace $ns protects a single pod."
                        echo "         Drain/eviction will cause SERVICE DOWNTIME."
                    fi
                    echo "Backing up PDB: $pdb in namespace: $ns"
                    oc get pdb "$pdb" -n "$ns" -o yaml | \
                        sed '/resourceVersion:/d; /uid:/d; /creationTimestamp:/d; /generation:/d; /selfLink:/d; /managedFields:/,/^[^ ]/{ /^[^ ]/!d; }' \
                        > "$backup_path/$ns/${pdb}.yaml"
                else
                    echo "Skipping PDB: $pdb in namespace: $ns (disruptionsAllowed > 0)"
                fi
            done
        fi
    done
    
    echo "Backup complete: $backup_path"
}

delete_pdbs() {
    local namespace="${1:-all}"
    
    if [[ "$namespace" == "all" ]]; then
        echo "Deleting PDBs from user namespaces (skipping system namespaces)..."
        namespaces=$(get_user_namespaces)
    else
        if is_system_namespace "$namespace"; then
            echo "Warning: $namespace is a system namespace. Skipping."
            return 1
        fi
        namespaces="$namespace"
    fi
    
    for ns in $namespaces; do
        pdbs=$(oc get pdb -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        for pdb in $pdbs; do
            if pdb_allowed_disruptions "$pdb" "$ns"; then
                echo "Deleting PDB: $pdb in namespace: $ns"
                oc delete pdb "$pdb" -n "$ns" --force --grace-period=0
            else
                echo "Skipping PDB: $pdb in namespace: $ns (disruptionsAllowed > 0)"
            fi
        done
    done
    
    echo "Deletion complete"
}

restore_pdbs() {
    local backup_path="$1"
    
    if [[ -z "$backup_path" || ! -d "$backup_path" ]]; then
        echo "Error: Provide a valid backup path"
        echo "Available backups:"
        ls -la "$BACKUP_DIR" 2>/dev/null || echo "No backups found"
        return 1
    fi
    
    for ns_dir in "$backup_path"/*; do
        if [[ -d "$ns_dir" ]]; then
            ns=$(basename "$ns_dir")
            for pdb_file in "$ns_dir"/*.yaml; do
                if [[ -f "$pdb_file" ]]; then
                    echo "Restoring: $pdb_file to namespace: $ns"
                    oc apply -f "$pdb_file" -n "$ns"
                fi
            done
        fi
    done
    
    echo "Restore complete"
}

list_backups() {
    echo "Available backups:"
    ls -la "$BACKUP_DIR" 2>/dev/null || echo "No backups found"
}

show_skipped() {
    echo "Skipped namespace patterns:"
    echo "  - openshift"
    echo "  - openshift-*"
    echo "  - kube-*"
    echo "  - default"
    echo "  - redhat-*"
    echo "  - rosa-*"
}

# Main
case "$1" in
    backup)
        backup_pdbs "$2"
        ;;
    delete)
        backup_pdbs "$2"
        delete_pdbs "$2"
        ;;
    restore)
        restore_pdbs "$2"
        ;;
    list)
        list_backups
        ;;
    skipped)
        show_skipped
        ;;
    *)
        echo "Usage: $0 {backup|delete|restore|list|skipped} [namespace|backup-path]"
        echo ""
        echo "Commands:"
        echo "  backup [namespace]     - Backup PDBs (skips system namespaces)"
        echo "  delete [namespace]     - Backup then delete PDBs (skips system namespaces)"
        echo "  restore <backup-path>  - Restore PDBs from backup"
        echo "  list                   - List available backups"
        echo "  skipped                - Show which namespaces are skipped"
        echo ""
        echo "Examples:"
        echo "  $0 backup                     # Backup all user PDBs"
        echo "  $0 backup my-namespace        # Backup PDBs in specific namespace"
        echo "  $0 delete                     # Backup and delete all user PDBs"
        echo "  $0 restore ./pdb-backups/20240115-120000"
        ;;
esac
