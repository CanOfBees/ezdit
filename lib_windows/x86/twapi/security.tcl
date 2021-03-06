#
# Copyright (c) 2003-2009, Ashok P. Nadkarni
# All rights reserved.
#
# See the file LICENSE for license

# TBD - allow SID and account name to be used interchangeably in various
# functions
# TBD - ditto for LUID v/s privilege names

namespace eval twapi {
    # Map privilege level mnemonics to priv level
    array set priv_level_map {guest 0 user 1 admin 2}

    # Map of Sid integer type to Sid type name
    array set sid_type_names {
        1 user 
        2 group
        3 domain 
        4 alias 
        5 wellknowngroup
        6 deletedaccount
        7 invalid
        8 unknown
        9 computer
    }

    # Well known group to SID mapping
    array set well_known_sids {
        nullauthority     S-1-0
        nobody            S-1-0-0
        worldauthority    S-1-1
        everyone          S-1-1-0
        localauthority    S-1-2
        creatorauthority  S-1-3
        creatorowner      S-1-3-0
        creatorgroup      S-1-3-1
        creatorownerserver  S-1-3-2
        creatorgroupserver  S-1-3-3
        ntauthority       S-1-5
        dialup            S-1-5-1
        network           S-1-5-2
        batch             S-1-5-3
        interactive       S-1-5-4
        service           S-1-5-6
        anonymouslogon    S-1-5-7
        proxy             S-1-5-8
        serverlogon       S-1-5-9
        authenticateduser S-1-5-11
        terminalserver    S-1-5-13
        localsystem       S-1-5-18
        localservice      S-1-5-19
        networkservice    S-1-5-20
    }

    # Built-in accounts
    # TBD - see http://support.microsoft.com/?kbid=243330 for more built-ins
    array set builtin_account_sids {
        administrators  S-1-5-32-544
        users           S-1-5-32-545
        guests          S-1-5-32-546
        "power users"   S-1-5-32-547
    }
}

#
# Helper for lookup_account_name{sid,name}
proc twapi::_lookup_account {func account args} {
    if {$func == "LookupAccountSid"} {
        set lookup name
        # If we are mapping a SID to a name, check if it is the logon SID
        # LookupAccountSid returns an error for this SID
        if {[is_valid_sid_syntax $account] &&
            [string match -nocase "S-1-5-5-*" $account]} {
            set name "Logon SID"
            set domain "NT AUTHORITY"
            set type "logonid"
        }
    } else {
        set lookup sid
    }
    array set opts [parseargs args \
                        [list all \
                             $lookup \
                             domain \
                             type \
                             [list system.arg ""]\
                            ]]


    # Lookup the info if have not already hardcoded results
    if {![info exists domain]} {
        foreach "$lookup domain type" [$func $opts(system) $account] break
    }

    set result [list ]
    if {$opts(all) || $opts(domain)} {
        lappend result -domain $domain
    }
    if {$opts(all) || $opts(type)} {
        lappend result -type $twapi::sid_type_names($type)
    }

    if {$opts(all) || $opts($lookup)} {
        lappend result -$lookup [set $lookup]
    }

    # If no options specified, only return the sid/name
    if {[llength $result] == 0} {
        return [set $lookup]
    }

    return $result
}

# Returns the sid, domain and type for an account
proc twapi::lookup_account_name {name args} {
    return [eval [list _lookup_account LookupAccountName $name] $args]
}


# Returns the name, domain and type for an account
proc twapi::lookup_account_sid {sid args} {
    return [eval [list _lookup_account LookupAccountSid $sid] $args]
}

#
# Returns the sid for a account - may be given as a SID or name
proc twapi::map_account_to_sid {account args} {
    array set opts [parseargs args {system.arg} -nulldefault]

    # Treat empty account as null SID (self)
    if {[string length $account] == ""} {
        return ""
    }

    if {[is_valid_sid_syntax $account]} {
        return $account
    } else {
        return [lookup_account_name $account -system $opts(system)]
    }
}


#
# Returns the name for a account - may be given as a SID or name
proc twapi::map_account_to_name {account args} {
    array set opts [parseargs args {system.arg} -nulldefault]

    if {[is_valid_sid_syntax $account]} {
        return [lookup_account_sid $account -system $opts(system)]
    } else {
        # Verify whether a valid account by mapping to an sid
        if {[catch {map_account_to_sid $account -system $opts(system)}]} {
            # As a special case, change LocalSystem to SYSTEM. Some Windows
            # API's (such as services) return LocalSystem which cannot be
            # resolved by the security functions. This name is really the
            # same a the built-in SYSTEM
            if {$account == "LocalSystem"} {
                return "SYSTEM"
            }
            error "Unknown account '$account'"
        } 
        return $account
    }
}

#
# Return the user account for the current process
proc twapi::get_current_user {{format -samcompatible}} {

    set return_sid false
    switch -exact -- $format {
        -fullyqualifieddn {set format 1}
        -samcompatible {set format 2}
        -display {set format 3}
        -uniqueid {set format 6}
        -canonical {set format 7}
        -userprincipal {set format 8}
        -canonicalex {set format 9}
        -serviceprincipal {set format 10}
        -dnsdomain {set format 12}
        -sid {set format 2 ; set return_sid true}
        default {
            error "Unknown user name format '$format'"
        }
    }

    set user [GetUserNameEx $format]

    if {$return_sid} {
        return [map_account_to_sid $user]
    } else {
        return $user
    }
}

#
# Verify that the given sid is valid. This is purely a syntactic check
proc twapi::is_valid_sid_syntax sid {
    try {
        set result [IsValidSid $sid]
    } onerror {TWAPI_WIN32 1337} {
        set result 0
    }

    return $result
}

#
# Returns token for the process with pid $pid
proc twapi::open_process_token {args} {
    variable windefs

    array set opts [parseargs args {
        pid.int
        {access.arg token_query}
    } -maxleftover 0]

    set access [_access_rights_to_mask $opts(access)]

    # If "Win2K all access" specified, modify for NT 4.0 else we get an error
    if {($access == $windefs(TOKEN_ALL_ACCESS_WIN2K))
        && ([lindex [get_os_version] 0] == 4)} {
        set access $windefs(TOKEN_ALL_ACCESS_WINNT)
    }

    # Get a handle for the process
    if {[info exists opts(pid)]} {
        set ph [OpenProcess $windefs(PROCESS_QUERY_INFORMATION) 0 $opts(pid)]
    } else {
        variable my_process_handle
        set ph $my_process_handle
    }
    try {
        # Get a token for the process
        set ptok [OpenProcessToken $ph $access]
    } finally {
        # Close handle only if we did an OpenProcess
        if {[info exists opts(pid)]} {
            CloseHandle $ph
        }
    }

    return $ptok
}


#
# Returns token for the thread with tid $tid. If $tid is "", current thread
# is assumed
proc twapi::open_thread_token {args} {
    variable windefs

    array set opts [parseargs args {
        tid.int
        {access.arg token_query}
        {self.bool  false}
    } -maxleftover 0]

    set access [_access_rights_to_mask $opts(access)]

    # If "Win2K all access" specified, modify for NT 4.0 else we get an error
    if {($access == $windefs(TOKEN_ALL_ACCESS_WIN2K))
        && ([lindex [get_os_version] 0] == 4)} {
        set access $windefs(TOKEN_ALL_ACCESS_WINNT)
    }

    # Get a handle for the thread
    if {[info exists opts(tid)]} {
        set th [get_thread_handle $opts(tid)]
    } else {
        set th [GetCurrentThread]
    }
    try {
        # Get a token for the process
        set ttok [OpenThreadToken $th $access $opts(self)]
    } finally {
        # Close handle only if we did an OpenProcess
        if {[info exists opts(tid)]} {
            CloseHandle $th
        }
    }

    return $ttok
}

#
# Close a token
proc twapi::close_token {tok} {
    CloseHandle $tok
}

#
# Get the user account associated with a token
proc twapi::get_token_user {tok args} {
    array set opts [parseargs args [list name]]
    set user [lindex [GetTokenInformation $tok $twapi::windefs(TokenUser)] 0]
    if {$opts(name)} {
        set user [lookup_account_sid $user]
    }
    return $user
}

#
# Get the groups associated with a token
proc twapi::get_token_groups {tok args} {
    array set opts [parseargs args [list name] -maxleftover 0]

    set groups [list ]
    foreach {group} [GetTokenInformation $tok $twapi::windefs(TokenGroups)] {
        set group [lindex $group 0]
        if {$opts(name)} {
            set group [lookup_account_sid $group]
        }
        lappend groups $group
    }

    return $groups
}

#
# Get the groups associated with a token along with their attributes
# These are returned as a flat list of the form "sid attrlist sid attrlist..."
# where the attrlist is a list of attributes
proc twapi::get_token_group_sids_and_attrs {tok} {
    variable windefs 

    set sids_and_attrs [list ]
    foreach {group} [GetTokenInformation $tok $windefs(TokenGroups)] {
        foreach {sid attr} $group break
        set attr_list {enabled enabled_by_default logon_id
            mandatory owner resource use_for_deny_only}
        lappend sids_and_attrs $sid [_map_token_attr $attr $attr_list SE_GROUP]
    }

    return $sids_and_attrs
}

# Get list of privileges that are currently enabled for the token
# If -all is specified, returns a list {enabled_list disabled_list}
proc twapi::get_token_privileges {tok args} {
    variable windefs

    set all [expr {[lsearch -exact $args -all] >= 0}]

    set enabled_privs [list ]
    set disabled_privs [list ]
    foreach {item} [GetTokenInformation $tok $windefs(TokenPrivileges)] {
        set priv [map_luid_to_privilege [lindex $item 0] -mapunknown]
        if {[lindex $item 1] & $windefs(SE_PRIVILEGE_ENABLED)} {
            lappend enabled_privs $priv
        } else {
            lappend disabled_privs $priv
        }
    }

    if {$all} {
        return [list $enabled_privs $disabled_privs]
    } else {
        return $enabled_privs
    }
}

#
# Return true if the token has the given privilege
proc twapi::check_enabled_privileges {tok privlist args} {
    set all_required [expr {[lsearch -exact $args "-any"] < 0}]

    if {0} {
        We now call the PrivilegeCheck instead. Not sure it matters
        This code also does not handle -any option
        foreach priv $privlist {
            if {[expr {
                       [lsearch -exact [get_token_privileges $tok] $priv] < 0
                   }]} {
                return 0
            }
        }
        return 1
    } else {
        set luid_attr_list [list ]
        foreach priv $privlist {
            lappend luid_attr_list [list [map_privilege_to_luid $priv] 0]
        }
        return [Twapi_PrivilegeCheck $tok $luid_attr_list $all_required]
    }
}


#
# Enable specified privileges. Returns "" if the given privileges were
# already enabled, else returns the privileges that were modified
proc twapi::enable_privileges {privlist} {
    variable my_process_handle

    # Get our process token
    set tok [OpenProcessToken $my_process_handle 0x28]; # QUERY + ADJUST_PRIVS
    try {
        return [enable_token_privileges $tok $privlist]
    } finally {
        close_token $tok
    }
}


#
# Disable specified privileges. Returns "" if the given privileges were
# already enabled, else returns the privileges that were modified
proc twapi::disable_privileges {privlist} {
    variable my_process_handle

    # Get our process token
    set tok [OpenProcessToken $my_process_handle 0x28]; # QUERY + ADJUST_PRIVS
    try {
        return [disable_token_privileges $tok $privlist]
    } finally {
        close_token $tok
    }
}


#
# Execute the given script with the specified privileges.
# After the script completes, the original privileges are restored
proc twapi::eval_with_privileges {script privs args} {
    array set opts [parseargs args {besteffort} -maxleftover 0]

    if {[catch {enable_privileges $privs} privs_to_disable]} {
        if {! $opts(besteffort)} {
            return -code error -errorinfo $::errorInfo \
                -errorcode $::errorCode $privs_to_disable
        }
        set privs_to_disable [list ]
    }

    set code [catch {uplevel $script} result]
    switch $code {
        0 {
            disable_privileges $privs_to_disable
            return $result
        }
        1 {
            # Save error info before calling disable_privileges
            set erinfo $::errorInfo
            set ercode $::errorCode
            disable_privileges $privs_to_disable
            return -code error -errorinfo $::errorInfo \
                -errorcode $::errorCode $result
        }
        default {
            disable_privileges $privs_to_disable
            return -code $code $result
        }
    }
}


# Get the privilege associated with a token and their attributes
proc twapi::get_token_privileges_and_attrs {tok} {
    set privs_and_attrs [list ]
    foreach priv [GetTokenInformation $tok $twapi::windefs(TokenPrivileges)] {
        foreach {luid attr} $priv break
        set attr_list {enabled enabled_by_default used_for_access}
        lappend privs_and_attrs [map_luid_to_privilege $luid -mapunknown] \
            [_map_token_attr $attr $attr_list SE_PRIVILEGE]
    }

    return $privs_and_attrs

}


#
# Get the sid that will be used as the owner for objects created using this
# token. Returns name instead of sid if -name options specified
proc twapi::get_token_owner {tok args} {
    return [ _get_token_sid_field $tok TokenOwner $args]
}


#
# Get the sid that will be used as the primary group for objects created using
# this token. Returns name instead of sid if -name options specified
proc twapi::get_token_primary_group {tok args} {
    return [ _get_token_sid_field $tok TokenPrimaryGroup $args]
}


#
# Return the source of an access token
proc twapi::get_token_source {tok} {
    return [GetTokenInformation $tok $twapi::windefs(TokenSource)]
}


#
# Return the token type of an access token
proc twapi::get_token_type {tok} {
    if {[GetTokenInformation $tok $twapi::windefs(TokenType)]} {
        return "primary"
    } else {
        return "impersonation"
    }
}

#
# Return the token type of an access token
proc twapi::get_token_impersonation_level {tok} {
    return [_map_impersonation_level \
                [GetTokenInformation $tok \
                     $twapi::windefs(TokenImpersonationLevel)]]
}

#
# Return token statistics
proc twapi::get_token_statistics {tok} {
    array set stats {}
    set labels {luid authluid expiration type impersonationlevel
        dynamiccharged dynamicavailable groupcount
        privilegecount modificationluid}
    set statinfo [GetTokenInformation $tok $twapi::windefs(TokenStatistics)]
    foreach label $labels val $statinfo {
        set stats($label) $val
    }
    set stats(type) [expr {$stats(type) == 1 ? "primary" : "impersonation"}]
    set stats(impersonationlevel) [_map_impersonation_level $stats(impersonationlevel)]

    return [array get stats]
}


#
# Enable the privilege state of a token. Generates an error if
# the specified privileges do not exist in the token (either
# disabled or enabled), or cannot be adjusted
proc twapi::enable_token_privileges {tok privs} {
    variable windefs

    set luid_attrs [list]
    foreach priv $privs {
        lappend luid_attrs [list [map_privilege_to_luid $priv] $windefs(SE_PRIVILEGE_ENABLED)]
    }

    set privs [list ]
    foreach {item} [Twapi_AdjustTokenPrivileges $tok 0 $luid_attrs] {
        lappend privs [map_luid_to_privilege [lindex $item 0] -mapunknown]
    }
    return $privs

    

}

#
# Disable the privilege state of a token. Generates an error if
# the specified privileges do not exist in the token (either
# disabled or enabled), or cannot be adjusted
proc twapi::disable_token_privileges {tok privs} {
    set luid_attrs [list]
    foreach priv $privs {
        lappend luid_attrs [list [map_privilege_to_luid $priv] 0]
    }

    set privs [list ]
    foreach {item} [Twapi_AdjustTokenPrivileges $tok 0 $luid_attrs] {
        lappend privs [map_luid_to_privilege [lindex $item 0] -mapunknown]
    }
    return $privs
}

#
# Disable all privs in a token
proc twapi::disable_all_token_privileges {tok} {
    set privs [list ]
    foreach {item} [Twapi_AdjustTokenPrivileges $tok 1 [list ]] {
        lappend privs [map_luid_to_privilege [lindex $item 0] -mapunknown]
    }
    return $privs
}


#
# Map a privilege given as a LUID
proc twapi::map_luid_to_privilege {luid args} {
    
    array set opts [parseargs args [list system.arg mapunknown] -nulldefault]

    # luid may in fact be a privilege name. Check for this
    if {[is_valid_luid_syntax $luid]} {
        try {
            set name [LookupPrivilegeName $opts(system) $luid]
        } onerror {TWAPI_WIN32 1313} {
            if {! $opts(mapunknown)} {
                error $errorResult $errorInfo $errorCode
            }
            set name "Privilege-$luid"
        }
    } else {
        # Not a valid LUID syntax. Check if it's a privilege name
        if {[catch {map_privilege_to_luid $luid -system $opts(system)}]} {
            error "Invalid LUID '$luid'"
        }
        return $luid;                   # $luid is itself a priv name
    }

    return $name
}


#
# Map a privilege to a LUID
proc twapi::map_privilege_to_luid {priv args} {
    array set opts [parseargs args [list system.arg] -nulldefault]

    # First check for privilege names we might have generated
    if {[string match "Privilege-*" $priv]} {
        set priv [string range $priv 10 end]
    }

    # If already a LUID format, return as is
    if {[is_valid_luid_syntax $priv]} {
        return $priv
    }
    return [LookupPrivilegeValue $opts(system) $priv]
}


#
# Return 1/0 if in LUID format
proc twapi::is_valid_luid_syntax {luid} {
    return [regexp {^[[:xdigit:]]{8}-[[:xdigit:]]{8}$} $luid]
}


################################################################
# Functions related to ACE's and ACL's

#
# Create a new ACE
proc twapi::new_ace {type account rights args} {
    variable windefs

    array set opts [parseargs args {
        {self.bool 1}
        {recursecontainers.bool 0}
        {recurseobjects.bool 0}
        {recurseonelevelonly.bool 0}
    }]

    set sid [map_account_to_sid $account]

    set access_mask [_access_rights_to_mask $rights]

    switch -exact -- $type {
        allow -
        deny  -
        audit {
            set typecode [_ace_type_symbol_to_code $type]
        }
        default {
            error "Invalid or unsupported ACE type '$type'"
        }
    }

    set inherit_flags 0
    if {! $opts(self)} {
        setbits inherit_flags $windefs(INHERIT_ONLY_ACE)
    }

    if {$opts(recursecontainers)} {
        setbits inherit_flags $windefs(CONTAINER_INHERIT_ACE)
    }

    if {$opts(recurseobjects)} {
        setbits inherit_flags $windefs(OBJECT_INHERIT_ACE)
    }

    if {$opts(recurseonelevelonly)} {
        setbits inherit_flags $windefs(NO_PROPAGATE_INHERIT_ACE)
    }

    return [list $typecode $inherit_flags $access_mask $sid]
}

#
# Get the ace type (allow, deny etc.)
proc twapi::get_ace_type {ace} {
    return [_ace_type_code_to_symbol [lindex $ace 0]]
}


#
# Set the ace type (allow, deny etc.)
proc twapi::set_ace_type {ace type} {
    return [lreplace $ace 0 0 [_ace_type_symbol_to_code $type]]
}

#
# Get the access rights in an ACE
proc twapi::get_ace_rights {ace args} {
    array set opts [parseargs args {type.arg raw} -nulldefault]
    if {$opts(raw)} {
        return [format 0x%x [lindex $ace 2]]
    } else {
        return [_access_mask_to_rights [lindex $ace 2] $opts(type)]
    }
}

#
# Set the access rights in an ACE
proc twapi::set_ace_rights {ace rights} {
    return [lreplace $ace 2 2 [_access_rights_to_mask $rights]]
}


#
# Get the ACE sid
proc twapi::get_ace_sid {ace} {
    return [lindex $ace 3]
}

#
# Set the ACE sid
proc twapi::set_ace_sid {ace account} {
    return [lreplace $ace 3 3 [map_account_to_sid $account]]
}


#
# Get the inheritance options
proc twapi::get_ace_inheritance {ace} {
    variable windefs
    
    set inherit_opts [list ]
    set inherit_mask [lindex $ace 1]

    lappend inherit_opts -self \
        [expr {($inherit_mask & $windefs(INHERIT_ONLY_ACE)) == 0}]
    lappend inherit_opts -recursecontainers \
        [expr {($inherit_mask & $windefs(CONTAINER_INHERIT_ACE)) != 0}]
    lappend inherit_opts -recurseobjects \
        [expr {($inherit_mask & $windefs(OBJECT_INHERIT_ACE)) != 0}]
    lappend inherit_opts -recurseonelevelonly \
        [expr {($inherit_mask & $windefs(NO_PROPAGATE_INHERIT_ACE)) != 0}]
    lappend inherit_opts -inherited \
        [expr {($inherit_mask & $windefs(INHERITED_ACE)) != 0}]

    return $inherit_opts
}

#
# Set the inheritance options. Unspecified options are not set
proc twapi::set_ace_inheritance {ace args} {
    variable windefs

    array set opts [parseargs args {
        self.bool
        recursecontainers.bool
        recurseobjects.bool
        recurseonelevelonly.bool
    }]
    
    set inherit_flags [lindex $ace 1]
    if {[info exists opts(self)]} {
        if {$opts(self)} {
            resetbits inherit_flags $windefs(INHERIT_ONLY_ACE)
        } else {
            setbits   inherit_flags $windefs(INHERIT_ONLY_ACE)
        }
    }

    foreach {
        opt                 mask
    } {
        recursecontainers   CONTAINER_INHERIT_ACE
        recurseobjects      OBJECT_INHERIT_ACE
        recurseonelevelonly NO_PROPAGATE_INHERIT_ACE
    } {
        if {[info exists opts($opt)]} {
            if {$opts($opt)} {
                setbits inherit_flags $windefs($mask)
            } else {
                resetbits inherit_flags $windefs($mask)
            }
        }
    }

    return [lreplace $ace 1 1 $inherit_flags]
}


#
# Sort ACE's in the standard recommended Win2K order
proc twapi::sort_aces {aces} {
    variable windefs

    _init_ace_type_symbol_to_code_map

    foreach type [array names twapi::_ace_type_symbol_to_code_map] {
        set direct_aces($type) [list ]
        set inherited_aces($type) [list ]
    }
    
    # Sort order is as follows: all direct (non-inherited) ACEs come
    # before all inherited ACEs. Within these groups, the order should be
    # access denied ACEs, access denied ACEs for objects/properties,
    # access allowed ACEs, access allowed ACEs for objects/properties,
    foreach ace $aces {
        set type [get_ace_type $ace]
        if {[lindex $ace 1] & $windefs(INHERITED_ACE)} {
            lappend inherited_aces($type) $ace
        } else {
            lappend direct_aces($type) $ace
        }
    }

    # TBD - check this order
    return [concat \
                $direct_aces(deny) \
                $direct_aces(deny_object) \
                $direct_aces(deny_callback) \
                $direct_aces(deny_callback_object) \
                $direct_aces(allow) \
                $direct_aces(allow_object) \
                $direct_aces(allow_compound) \
                $direct_aces(allow_callback) \
                $direct_aces(allow_callback_object) \
                $direct_aces(audit) \
                $direct_aces(audit_object) \
                $direct_aces(audit_callback) \
                $direct_aces(audit_callback_object) \
                $direct_aces(alarm) \
                $direct_aces(alarm_object) \
                $direct_aces(alarm_callback) \
                $direct_aces(alarm_callback_object) \
                $inherited_aces(deny) \
                $inherited_aces(deny_object) \
                $inherited_aces(deny_callback) \
                $inherited_aces(deny_callback_object) \
                $inherited_aces(allow) \
                $inherited_aces(allow_object) \
                $inherited_aces(allow_compound) \
                $inherited_aces(allow_callback) \
                $inherited_aces(allow_callback_object) \
                $inherited_aces(audit) \
                $inherited_aces(audit_object) \
                $inherited_aces(audit_callback) \
                $inherited_aces(audit_callback_object) \
                $inherited_aces(alarm) \
                $inherited_aces(alarm_object) \
                $inherited_aces(alarm_callback) \
                $inherited_aces(alarm_callback_object)]
}

#
# Pretty print an ACE
proc twapi::get_ace_text {ace args} {
    array set opts [parseargs args {
        {resourcetype.arg raw}
        {offset.arg ""}
    } -maxleftover 0]

    if {$ace eq "null"} {
        return "Null"
    }

    set offset $opts(offset)
    array set bools {0 No 1 Yes}
    array set inherit_flags [get_ace_inheritance $ace]
    append inherit_text "${offset}Inherited: $bools($inherit_flags(-inherited))\n"
    append inherit_text "${offset}Include self: $bools($inherit_flags(-self))\n"
    append inherit_text "${offset}Recurse containers: $bools($inherit_flags(-recursecontainers))\n"
    append inherit_text "${offset}Recurse objects: $bools($inherit_flags(-recurseobjects))\n"
    append inherit_text "${offset}Recurse single level only: $bools($inherit_flags(-recurseonelevelonly))\n"
    
    set rights [get_ace_rights $ace -type $opts(resourcetype)]
    if {[lsearch -glob $rights *_all_access] >= 0} {
        set rights "All"
    } else {
        set rights [join $rights ", "]
    }

    append result "${offset}Type: [string totitle [get_ace_type $ace]]\n"
    append result "${offset}User: [map_account_to_name [get_ace_sid $ace]]\n"
    append result "${offset}Rights: $rights\n"
    append result $inherit_text

    return $result
}

#
# Create a new ACL
proc twapi::new_acl {{aces ""}} {
    variable windefs

    set acl_rev $windefs(ACL_REVISION)
    
    foreach ace $aces {
        set ace_typecode [lindex $ace 0]
        if {$ace_typecode != $windefs(ACCESS_ALLOWED_ACE_TYPE) &&
            $ace_typecode != $windefs(ACCESS_DENIED_ACE_TYPE) &&
            $ace_typecode != $windefs(SYSTEM_AUDIT_ACE_TYPE)} {
            set acl_rev $windefs(ACL_REVISION_DS)
            break
        }
    }

    return [list $acl_rev $aces]
}

#
# Return the list of ACE's in an ACL
proc twapi::get_acl_aces {acl} {
    return [lindex $acl 1]
}

#
# Set the ACE's in an ACL
proc twapi::set_acl_aces {acl aces} {
    # Note, we call new_acl since when ACEs change, the rev may also change
    return [new_acl $aces]
}

#
# Append to the ACE's in an ACL
proc twapi::append_acl_aces {acl aces} {
    return [set_acl_aces $acl [concat [get_acl_aces $acl] $aces]]
}

#
# Prepend to the ACE's in an ACL
proc twapi::prepend_acl_aces {acl aces} {
    return [set_acl_aces $acl [concat $aces [get_acl_aces $acl]]]
}

#
# Arrange the ACE's in an ACL in a standard order
proc twapi::sort_acl_aces {acl} {
    return [set_acl_aces $acl [sort_aces [get_acl_aces $acl]]]
}

#
# Return the ACL revision of an ACL
proc twapi::get_acl_rev {acl} {
    return [lindex $acl 0]
}


#
# Create a new security descriptor
proc twapi::new_security_descriptor {args} {
    array set opts [parseargs args {
        owner.arg
        group.arg
        dacl.arg
        sacl.arg
    }]

    set secd [Twapi_InitializeSecurityDescriptor]

    foreach field {owner group dacl sacl} {
        if {[info exists opts($field)]} {
            set secd [set_security_descriptor_$field $secd $opts($field)]
        }
    }

    return $secd
}

#
# Return the control bits in a security descriptor
proc twapi::get_security_descriptor_control {secd} {
    if {[_null_secd $secd]} {
        error "Attempt to get control field from NULL security descriptor."
    }

    set control [lindex $secd 0]
    
    set retval [list ]
    if {$control & 0x0001} {
        lappend retval owner_defaulted
    }
    if {$control & 0x0002} {
        lappend retval group_defaulted
    }
    if {$control & 0x0004} {
        lappend retval dacl_present
    }
    if {$control & 0x0008} {
        lappend retval dacl_defaulted
    }
    if {$control & 0x0010} {
        lappend retval sacl_present
    }
    if {$control & 0x0020} {
        lappend retval sacl_defaulted
    }
    if {$control & 0x0100} {
        lappend retval dacl_auto_inherit_req
    }
    if {$control & 0x0200} {
        lappend retval sacl_auto_inherit_req
    }
    if {$control & 0x0400} {
        lappend retval dacl_auto_inherited
    }
    if {$control & 0x0800} {
        lappend retval sacl_auto_inherited
    }
    if {$control & 0x1000} {
        lappend retval dacl_protected
    }
    if {$control & 0x2000} {
        lappend retval sacl_protected
    }
    if {$control & 0x4000} {
        lappend retval rm_control_valid
    }
    if {$control & 0x8000} {
        lappend retval self_relative
    }
    return $retval
}

#
# Return the owner in a security descriptor
proc twapi::get_security_descriptor_owner {secd} {
    if {[_null_secd $secd]} {
        win32_error 87 "Attempt to get owner field from NULL security descriptor."
    }
    return [lindex $secd 1]
}

#
# Set the owner in a security descriptor
proc twapi::set_security_descriptor_owner {secd account} {
    if {[_null_secd $secd]} {
        set secd [new_security_descriptor]
    }
    set sid [map_account_to_sid $account]
    return [lreplace $secd 1 1 $sid]
}

#
# Return the group in a security descriptor
proc twapi::get_security_descriptor_group {secd} {
    if {[_null_secd $secd]} {
        win32_error 87 "Attempt to get group field from NULL security descriptor."
    }
    return [lindex $secd 2]
}

#
# Set the group in a security descriptor
proc twapi::set_security_descriptor_group {secd account} {
    if {[_null_secd $secd]} {
        set secd [new_security_descriptor]
    }
    set sid [map_account_to_sid $account]
    return [lreplace $secd 2 2 $sid]
}

#
# Return the DACL in a security descriptor
proc twapi::get_security_descriptor_dacl {secd} {
    if {[_null_secd $secd]} {
        win32_error 87 "Attempt to get DACL field from NULL security descriptor."
    }
    return [lindex $secd 3]
}

#
# Set the dacl in a security descriptor
proc twapi::set_security_descriptor_dacl {secd acl} {
    if {[_null_secd $secd]} {
        set secd [new_security_descriptor]
    }
    return [lreplace $secd 3 3 $acl]
}

#
# Return the SACL in a security descriptor
proc twapi::get_security_descriptor_sacl {secd} {
    if {[_null_secd $secd]} {
        win32_error 87 "Attempt to get SACL field from NULL security descriptor."
    }
    return [lindex $secd 4]
}

#
# Set the sacl in a security descriptor
proc twapi::set_security_descriptor_sacl {secd acl} {
    if {[_null_secd $secd]} {
        set secd [new_security_descriptor]
    }
    return [lreplace $secd 4 4 $acl]
}

#
# Get the specified security information for the given object
proc twapi::get_resource_security_descriptor {restype name args} {
    variable windefs

    array set opts [parseargs args {
        owner
        group
        dacl
        sacl
        all
        handle
    }]

    set wanted 0

    foreach field {owner group dacl sacl} {
        if {$opts($field) || $opts(all)} {
            set wanted [expr {$wanted | $windefs([string toupper $field]_SECURITY_INFORMATION)}]
        }
    }

    # Note if no options specified, we ask for everything except
    # SACL's which require special privileges
    if {! $wanted} {
        foreach field {owner group dacl} {
            set wanted [expr {$wanted | $windefs([string toupper $field]_SECURITY_INFORMATION)}]
        }
        set opts($field) 1
    }

    if {$opts(handle)} {
        set secd [Twapi_GetSecurityInfo \
                      [CastToHANDLE $name] \
                      [_map_resource_symbol_to_type $restype false] \
                      $wanted]
    } else {
        # GetNamedSecurityInfo seems to fail with a overlapped i/o
        # in progress error under some conditions. If this happens
        # try getting with resource-specific API's if possible.
        try {
            set secd [Twapi_GetNamedSecurityInfo \
                          $name \
                          [_map_resource_symbol_to_type $restype true] \
                          $wanted]
        } onerror {} {
            # TBD - see what other resource-specific API's there are
            if {$restype eq "share"} {
                set secd [lindex [get_share_info $name -secd] 1]
            } else {
                # Throw the same error
                error $errorResult $errorInfo $errorCode
            }
        }
    }

    return $secd
}


#
# Set the specified security information for the given object
# See http://search.cpan.org/src/TEVERETT/Win32-Security-0.50/README
# for a good discussion even though that applies to Perl
proc twapi::set_resource_security_descriptor {restype name secd args} {
    variable windefs

    array set opts [parseargs args {
        handle
        owner
        group
        dacl
        sacl
        all
        protect_dacl
        unprotect_dacl
        protect_sacl
        unprotect_sacl
    }]

    set mask 0

    if {[min_os_version 5 0]} {
        # Only win2k and above. Ignore otherwise

        if {$opts(protect_dacl) && $opts(unprotect_dacl)} {
            error "Cannot specify both -protect_dacl and -unprotect_dacl."
        }

        if {$opts(protect_dacl)} {
            setbits mask $windefs(PROTECTED_DACL_SECURITY_INFORMATION)
        }
        if {$opts(unprotect_dacl)} {
            setbits mask $windefs(UNPROTECTED_DACL_SECURITY_INFORMATION)
        }

        if {$opts(protect_sacl) && $opts(unprotect_sacl)} {
            error "Cannot specify both -protect_sacl and -unprotect_sacl."
        }

        if {$opts(protect_sacl)} {
            setbits mask $windefs(PROTECTED_SACL_SECURITY_INFORMATION)
        }
        if {$opts(unprotect_sacl)} {
            setbits mask $windefs(UNPROTECTED_SACL_SECURITY_INFORMATION)
        }

    }

    if {$opts(owner) || $opts(all)} {
        set opts(owner) [get_security_descriptor_owner $secd]
        setbits mask $windefs(OWNER_SECURITY_INFORMATION)
    } else {
        set opts(owner) ""
    }

    if {$opts(group) || $opts(all)} {
        set opts(group) [get_security_descriptor_group $secd]
        setbits mask $windefs(GROUP_SECURITY_INFORMATION)
    } else {
        set opts(group) ""
    }

    if {$opts(dacl) || $opts(all)} {
        set opts(dacl) [get_security_descriptor_dacl $secd]
        setbits mask $windefs(DACL_SECURITY_INFORMATION)
    } else {
        set opts(dacl) null
    }

    if {$opts(sacl) || $opts(all)} {
        set opts(sacl) [get_security_descriptor_sacl $secd]
        setbits mask $windefs(SACL_SECURITY_INFORMATION)
    } else {
        set opts(sacl) null
    }

    if {$opts(handle)} {
        SetSecurityInfo \
            [CastToHANDLE $name] \
            [_map_resource_symbol_to_type $restype false] \
            $mask \
            $opts(owner) \
            $opts(group) \
            $opts(dacl) \
            $opts(sacl)
    } else {
        SetNamedSecurityInfo \
            $name \
            [_map_resource_symbol_to_type $restype true] \
            $mask \
            $opts(owner) \
            $opts(group) \
            $opts(dacl) \
            $opts(sacl)
    }
}

#
# Return the text for a security descriptor
proc twapi::get_security_descriptor_text {secd args} {
    if {[_null_secd $secd]} {
        return "null"
    }

    array set opts [parseargs args {
        {resourcetype.arg raw}
    } -maxleftover 0]

    append result "Flags:\t[get_security_descriptor_control $secd]\n"
    append result "Owner:\t[map_account_to_name [get_security_descriptor_owner $secd]]\n"
    append result "Group:\t[map_account_to_name [get_security_descriptor_group $secd]]\n"

    set acl [get_security_descriptor_dacl $secd]
    append result "DACL Rev: [get_acl_rev $acl]\n"
    set index 0
    foreach ace [get_acl_aces $acl] {
        append result "\tDACL Entry [incr index]\n"
        append result "[get_ace_text $ace -offset "\t    " -resourcetype $opts(resourcetype)]"
    }

    set acl [get_security_descriptor_sacl $secd]
    append result "SACL Rev: [get_acl_rev $acl]\n"
    set index 0
    foreach ace [get_acl_aces $acl] {
        append result "\tSACL Entry $index\n"
        append result "[get_ace_text $ace -offset "\t    " -resourcetype $opts(resourcetype)]"
    }

    return $result
}


#
# Log off
proc twapi::logoff {args} {
    array set opts [parseargs args {force forceifhung}]
    set flags 0
    if {$opts(force)} {setbits flags 0x4}
    if {$opts(forceifhung)} {setbits flags 0x10}
    ExitWindowsEx $flags 0
}

#
# Lock the workstation
proc twapi::lock_workstation {} {
    LockWorkStation
}


#
# Get a new LUID
proc twapi::new_luid {} {
    return [AllocateLocallyUniqueId]
}

#
# TBD - maybe these UUID functions should not be in the security module
# Get a new uuid
proc twapi::new_uuid {{opt ""}} {
    if {[string length $opt]} {
        if {[string equal $opt "-localok"]} {
            set local_ok 1
        } else {
            error "Invalid or unknown argument '$opt'"
        }
    } else {
        set local_ok 0
    }
    return [UuidCreate $local_ok] 
}
proc twapi::nil_uuid {} {
    return [UuidCreateNil]
}


#
# Get the description of a privilege
proc twapi::get_privilege_description {priv} {
    if {[catch {LookupPrivilegeDisplayName "" $priv} desc]} {
        switch -exact -- $priv {
            # The above function will only return descriptions for
            # privileges, not account rights. Hard code descriptions
            # for some account rights
            SeBatchLogonRight { set desc "Log on as a batch job" }
            SeDenyBatchLogonRight { set desc "Deny logon as a batch job" }
            SeDenyInteractiveLogonRight { set desc "Deny logon locally" }
            SeDenyNetworkLogonRight { set desc "Deny access to this computer from the network" }
            SeDenyServiceLogonRight { set desc "Deny logon as a service" }
            SeInteractiveLogonRight { set desc "Log on locally" }
            SeNetworkLogonRight { set desc "Access this computer from the network" }
            SeServiceLogonRight { set desc "Log on as a service" }
            default {set desc ""}
        }
    }
    return $desc
}



# For backward compatibility, emulate GetUserName using GetUserNameEx
proc twapi::GetUserName {} {
    return [file tail [GetUserNameEx 2]]
}

################################################################
# Utility and helper functions



# Returns an sid field from a token
proc twapi::_get_token_sid_field {tok field options} {
    array set opts [parseargs options {name}]
    set owner [GetTokenInformation $tok $twapi::windefs($field)]
    if {$opts(name)} {
        set owner [lookup_account_sid $owner]
    }
    return $owner
}


#
# Map a token attribute mask to list of attribute names
proc twapi::_map_token_attr {attr names prefix} {
    variable windefs

    set attrs [list ]
    foreach attr_name $names {
        set attr_mask $windefs(${prefix}_[string toupper $attr_name])
        if {[expr {$attr & $attr_mask}]} {
            lappend attrs $attr_name
        }
    }

    return $attrs
}


#
# Map a set of access right symbols to a flag. Concatenates
# all the arguments, and then OR's the individual elements. Each
# element may either be a integer or one of the access rights
proc twapi::_access_rights_to_mask {args} {
    variable windefs

    set rights 0
    foreach right [eval concat $args] {
        if {![string is integer $right]} {
            if {$right == "token_all_access"} {
                if {[min_os_version 5 0]} {
                    set right $windefs(TOKEN_ALL_ACCESS_WIN2K)
                } else {
                    set right $windefs(TOKEN_ALL_ACCESS_WIN2K)
                }
            } else {
                if {[catch {set right $windefs([string toupper $right])}]} {
                    error "Invalid access right symbol '$right'"
                }
            }
        }
        set rights [expr {$rights | $right}]
    }

    return $rights
}


#
# Map an access mask to a set of rights
proc twapi::_access_mask_to_rights {access_mask {type ""}} {
    variable windefs

    set rights [list ]

    # The returned list will include rights that map to multiple bits
    # as well as the individual bits. We first add the multiple bits
    # and then the individual bits (since we clear individual bits
    # after adding)

    #
    # Check standard multiple bit masks
    #
    foreach x {STANDARD_RIGHTS_REQUIRED STANDARD_RIGHTS_READ STANDARD_RIGHTS_WRITE STANDARD_RIGHTS_EXECUTE STANDARD_RIGHTS_ALL SPECIFIC_RIGHTS_ALL} {
        if {($windefs($x) & $access_mask) == $windefs($x)} {
            lappend rights [string tolower $x]
        }
    }
    #
    # Check type specific multiple bit masks
    #
    switch -exact -- $type {
        file {
            set masks [list FILE_ALL_ACCESS FILE_GENERIC_READ FILE_GENERIC_WRITE FILE_GENERIC_EXECUTE]
        }
        pipe {
            set masks [list FILE_ALL_ACCESS]
        }
        service {
            set masks [list SERVICE_ALL_ACCESS]
        }
        registry {
            set masks [list KEY_READ KEY_WRITE KEY_EXECUTE KEY_ALL_ACCESS]
        }
        process {
            set masks [list PROCESS_ALL_ACCESS]
        }
        thread {
            set masks [list THREAD_ALL_ACCESS]
        }
        token {
            set masks [list TOKEN_READ TOKEN_WRITE TOKEN_EXECUTE]
            # TOKEN_ALL_ACCESS depends on platform
            if {[min_os_version 5 0]} {
                set token_all_access $windefs(TOKEN_ALL_ACCESS_WIN2K)
            } else {
                set token_all_access $windefs(TOKEN_ALL_ACCESS_WIN2K)
            }
            if {($token_all_access & $access_mask) == $token_all_access} {
                lappend rights "token_all_access"
            }
        }
        desktop {
            # THere is no desktop all access bits
        }
        winsta {
            set masks [list WINSTA_ALL_ACCESS]
        }
        default {
            set masks [list ]
        }
    }

    foreach x $masks {
        if {($windefs($x) & $access_mask) == $windefs($x)} {
            lappend rights [string tolower $x]
        }
    }


    #
    # OK, now map individual bits

    # First map the common bits
    foreach x {DELETE READ_CONTROL WRITE_DAC WRITE_OWNER SYNCHRONIZE} {
        if {$windefs($x) & $access_mask} {
            lappend rights [string tolower $x]
            resetbits access_mask $windefs($x)
        }
    }

    # Then the generic bits
    foreach x {GENERIC_READ GENERIC_WRITE GENERIC_EXECUTE GENERIC_ALL} {
        if {$windefs($x) & $access_mask} {
            lappend rights [string tolower $x]
            resetbits access_mask $windefs($x)
        }
    }

    # Then the type specific
    switch -exact -- $type {
        file {
            set masks {
                FILE_READ_DATA
                FILE_WRITE_DATA
                FILE_APPEND_DATA
                FILE_READ_EA
                FILE_WRITE_EA
                FILE_EXECUTE
                FILE_DELETE_CHILD
                FILE_READ_ATTRIBUTES
                FILE_WRITE_ATTRIBUTES
            }
        }
        pipe {
            set masks {
                FILE_READ_DATA
                FILE_WRITE_DATA
                FILE_CREATE_PIPE_INSTANCE
                FILE_READ_ATTRIBUTES
                FILE_WRITE_ATTRIBUTES
            }
        }
        service {
            set masks {
                SERVICE_QUERY_CONFIG
                SERVICE_CHANGE_CONFIG
                SERVICE_QUERY_STATUS
                SERVICE_ENUMERATE_DEPENDENTS
                SERVICE_START
                SERVICE_STOP
                SERVICE_PAUSE_CONTINUE
                SERVICE_INTERROGATE
                SERVICE_USER_DEFINED_CONTROL
            }
        }
        registry {
            set masks {
                KEY_QUERY_VALUE
                KEY_SET_VALUE
                KEY_CREATE_SUB_KEY
                KEY_ENUMERATE_SUB_KEYS
                KEY_NOTIFY
                KEY_CREATE_LINK
                KEY_WOW64_32KEY
                KEY_WOW64_64KEY
                KEY_WOW64_RES
            }
        }
        process {
            set masks {
                PROCESS_TERMINATE
                PROCESS_CREATE_THREAD
                PROCESS_SET_SESSIONID
                PROCESS_VM_OPERATION
                PROCESS_VM_READ
                PROCESS_VM_WRITE
                PROCESS_DUP_HANDLE
                PROCESS_CREATE_PROCESS
                PROCESS_SET_QUOTA
                PROCESS_SET_INFORMATION
                PROCESS_QUERY_INFORMATION
                PROCESS_SUSPEND_RESUME
            }
        }
        thread {
            set masks {
                THREAD_TERMINATE
                THREAD_SUSPEND_RESUME
                THREAD_GET_CONTEXT
                THREAD_SET_CONTEXT
                THREAD_SET_INFORMATION
                THREAD_QUERY_INFORMATION
                THREAD_SET_THREAD_TOKEN
                THREAD_IMPERSONATE
                THREAD_DIRECT_IMPERSONATION
            }
        }
        token {
            set masks {
                TOKEN_ASSIGN_PRIMARY
                TOKEN_DUPLICATE
                TOKEN_IMPERSONATE
                TOKEN_QUERY
                TOKEN_QUERY_SOURCE
                TOKEN_ADJUST_PRIVILEGES
                TOKEN_ADJUST_GROUPS
                TOKEN_ADJUST_DEFAULT
                TOKEN_ADJUST_SESSIONID
            }
        }
        desktop {
            set masks {
                DESKTOP_READOBJECTS
                DESKTOP_CREATEWINDOW
                DESKTOP_CREATEMENU
                DESKTOP_HOOKCONTROL
                DESKTOP_JOURNALRECORD
                DESKTOP_JOURNALPLAYBACK
                DESKTOP_ENUMERATE
                DESKTOP_WRITEOBJECTS
                DESKTOP_SWITCHDESKTOP
            }
        }
        windowstation -
        winsta {
            set masks {
                WINSTA_ENUMDESKTOPS
                WINSTA_READATTRIBUTES
                WINSTA_ACCESSCLIPBOARD
                WINSTA_CREATEDESKTOP
                WINSTA_WRITEATTRIBUTES
                WINSTA_ACCESSGLOBALATOMS
                WINSTA_EXITWINDOWS
                WINSTA_ENUMERATE
                WINSTA_READSCREEN
            }
        }
        default {
            set masks [list ]
        }
    }

    foreach x $masks {
        if {$windefs($x) & $access_mask} {
            lappend rights [string tolower $x]
            resetbits access_mask $windefs($x)
        }
    }

    # Finally add left over bits if any
    for {set i 0} {$i < 32} {incr i} {
        set x [expr {1 << $i}]
        if {$access_mask & $x} {
            lappend rights [format 0x%.8X $x]
        }
    }

    return $rights
}


#
# Map an ace type symbol (eg. allow) to the underlying ACE type code
proc twapi::_ace_type_symbol_to_code {type} {
    _init_ace_type_symbol_to_code_map
    return $::twapi::_ace_type_symbol_to_code_map($type)
}


#
# Map an ace type code to an ACE type symbol
proc twapi::_ace_type_code_to_symbol {type} {
    _init_ace_type_symbol_to_code_map
    return $::twapi::_ace_type_code_to_symbol_map($type)
}


# Init the arrays used for mapping ACE type symbols to codes and back
proc twapi::_init_ace_type_symbol_to_code_map {} {
    variable windefs

    if {[info exists ::twapi::_ace_type_symbol_to_code_map]} {
        return
    }

    # Define the array. Be careful to "normalize" the integer values
    array set ::twapi::_ace_type_symbol_to_code_map \
        [list \
             allow [expr { $windefs(ACCESS_ALLOWED_ACE_TYPE) + 0 }] \
             deny [expr  { $windefs(ACCESS_DENIED_ACE_TYPE) + 0 }] \
             audit [expr { $windefs(SYSTEM_AUDIT_ACE_TYPE) + 0 }] \
             alarm [expr { $windefs(SYSTEM_ALARM_ACE_TYPE) + 0 }] \
             allow_compound [expr { $windefs(ACCESS_ALLOWED_COMPOUND_ACE_TYPE) + 0 }] \
             allow_object [expr   { $windefs(ACCESS_ALLOWED_OBJECT_ACE_TYPE) + 0 }] \
             deny_object [expr    { $windefs(ACCESS_DENIED_OBJECT_ACE_TYPE) + 0 }] \
             audit_object [expr   { $windefs(SYSTEM_AUDIT_OBJECT_ACE_TYPE) + 0 }] \
             alarm_object [expr   { $windefs(SYSTEM_ALARM_OBJECT_ACE_TYPE) + 0 }] \
             allow_callback [expr { $windefs(ACCESS_ALLOWED_CALLBACK_ACE_TYPE) + 0 }] \
             deny_callback [expr  { $windefs(ACCESS_DENIED_CALLBACK_ACE_TYPE) + 0 }] \
             allow_callback_object [expr { $windefs(ACCESS_ALLOWED_CALLBACK_OBJECT_ACE_TYPE) + 0 }] \
             deny_callback_object [expr  { $windefs(ACCESS_DENIED_CALLBACK_OBJECT_ACE_TYPE) + 0 }] \
             audit_callback [expr { $windefs(SYSTEM_AUDIT_CALLBACK_ACE_TYPE) + 0 }] \
             alarm_callback [expr { $windefs(SYSTEM_ALARM_CALLBACK_ACE_TYPE) + 0 }] \
             audit_callback_object [expr { $windefs(SYSTEM_AUDIT_CALLBACK_OBJECT_ACE_TYPE) + 0 }] \
             alarm_callback_object [expr { $windefs(SYSTEM_ALARM_CALLBACK_OBJECT_ACE_TYPE) + 0 }] \
                 ]

    # Now define the array in the other direction
    foreach {sym code} [array get ::twapi::_ace_type_symbol_to_code_map] {
        set ::twapi::_ace_type_code_to_symbol_map($code) $sym
    }
}

#
# Construct a security attributes structure out of a security descriptor
# and inheritance flave
proc twapi::_make_secattr {secd inherit} {
    if {$inherit} {
        set sec_attr [list $secd 1]
    } else {
        if {$secd == ""} {
            # If a security descriptor not specified, keep
            # all security attributes as an empty list (ie. NULL)
            set sec_attr [list ]
        } else {
            set sec_attr [list $secd 0]
        }
    }
    return $sec_attr
}

#
# Map a resource symbol type to value
proc twapi::_map_resource_symbol_to_type {sym {named true}} {
    if {[string is integer $sym]} {
        return $sym
    }

    # Note "window" is not here because window stations and desktops
    # do not have unique names and cannot be used with Get/SetNamedSecurityInfo
    switch -exact -- $sym {
        file      { return 1 }
        service   { return 2 }
        printer   { return 3 }
        registry  { return 4 }
        share     { return 5 }
        kernelobj { return 6 }
    }
    if {$named} {
        error "Resource type '$restype' not valid for named resources."
    }

    switch -exact -- $sym {
        windowstation    { return 7 }
        directoryservice { return 8 }
        directoryserviceall { return 9 }
        providerdefined { return 10 }
        wmiguid { return 111 }
        registrywow6432key { return 12 }
    }

    error "Resource type '$restype' not valid"
}

#
# Valid LUID syntax
proc twapi::_is_valid_luid_syntax luid {
    return [regexp {^[[:xdigit:]]{8}-[[:xdigit:]]{8}$} $luid]
}


# Delete rights for an account
proc twapi::_delete_rights {account system} {
    # Remove the user from the LSA rights database. Ignore any errors
    catch {
        remove_account_rights $account {} -all -system $system

        # On Win2k SP1 and SP2, we need to delay a bit for notifications
        # to complete before deleting the account.
        # See http://support.microsoft.com/?id=316827
        foreach {major minor sp dontcare} [get_os_version] break
        if {($major == 5) && ($minor == 0) && ($sp < 3)} {
            after 1000
        }
    }
}

# Variable that maps logon session type codes to integer values
# See ntsecapi.h for definitions
set twapi::logon_session_type_map {
    0
    1
    interactive
    network
    batch
    service
    proxy
    unlockworkstation
    networkclear
    newcredentials
    remoteinteractive
    cachedinteractive
    cachedremoteinteractive
    cachedunlockworkstation
}

# Returns true if null security descriptor
proc twapi::_null_secd {secd} {
    if {[llength $secd] == 0} {
        return 1
    } else {
        return 0
    }
}

# Returns true if a valid ACL
proc twapi::_is_valid_acl {acl} {
    if {$acl eq "null"} {
        return 1
    } else {
        return [IsValidAcl $acl]
    }
}

# Returns true if a valid ACL
proc twapi::_is_valid_security_descriptor {secd} {
    if {[_null_secd $secd]} {
        return 1
    } else {
        return [IsValidSecurityDescriptor $secd]
    }
}
