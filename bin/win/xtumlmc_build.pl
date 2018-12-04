#!/usr/bin/perl
#===========================================================================
my $file_version = '1.61';
#
# Description:
# Run this file to build using SQL and marking input alone.  No
# repository is necessary.  Single and multiple domain builds are
# supported.  Input files can be .sql with no graphics or .sql with
# embedded graphics.
#
# This utility makes for a long command line, but it serves nicely
# when integrating with automated build environments.
#
# xtumlmc_build can also be used in conjunction with third-party version
# control systems (such as CVS, CleareCASE).  xtumlmc_build could also be
# used when building models extracted from multiple repositories.  A
# build server could use this utility to perform automatic translation
# of newly checked in materials.  xtumlmc_build also serves in test suite
# automation.
#
#===========================================================================

use POSIX;
use File::Copy;
use File::Path;
use File::Compare;
use File::Find;
use File::Basename;
use Cwd;
use Cwd 'abs_path';

my $osplatform;
my $windbase = "";
my %env_vars; # Perl can't export variables directly.  This
              # will hold the variables we would normally export
              # and we'll use system to export them later.

# Preprocess the command line for which mc we're using and the home directory
my $mc = "mc";
my $home_dir = "";
for ( my $i = 0; $i < @ARGV; $i++ ) {
  my $k = $ARGV[$i];
  if ( $k =~ /^(-2)$/ ) { $mc = "mc2020"; }
  elsif ( $k =~ /^(-3)$/ ) { $mc = "mc"; }
  elsif ( $k =~ /^(-home)$/ ) { 
    $i++; 
    if ( $ARGV[$i] =~ m/^\.\./ ) {
      $home_dir = pwd(); 
      $home_dir = "$home_dir/$ARGV[$i]"; 
    } else {
      $home_dir = $ARGV[$i]; 
    }
  }
}
if ( ! exists $ENV{'XTUMLMC_HOME'} ) {
  $ENV{'XTUMLMC_HOME'} = $home_dir;
}
$ENV{'ROX_MC_ROOT_DIR'} = "$ENV{'XTUMLMC_HOME'}/$mc" if ( ! exists $ENV{'ROX_MC_ROOT_DIR'} );
$ENV{'ROX_MC_BIN_DIR'} = "$ENV{'XTUMLMC_HOME'}/$mc/bin" if ( ! exists $ENV{'ROX_MC_BIN_DIR'} );

# Get the platform name, and set variables appropriately.
my @system_arr = uname();
my $system = "$system_arr[0]";
my $root_dir = $ENV{'ROX_MC_ROOT_DIR'};

# Set up platform specific environment.
if ( $system =~ m/windows/i ) {
  $osplatform = "win32";
  $ENV{'ROX_MC_BIN_DIR'} = $root_dir . "/bin";
  $ENV{'ROX_USE_CYGWIN'} = "FALSE";
} elsif ( $system =~ m/cygwin/i ) {
  $env_vars{'CYGWIN'} = $ENV{'CYGWIN'} = "nobinmode";
  $osplatform = "win32";
  $ENV{'ROX_MC_BIN_DIR'} = "$root_dir/bin";
  $ENV{'ROX_USE_CYGWIN'} = "TRUE";
} elsif ( $system =~ m/MINGW/i ) {
  $osplatform = "win32";
  $ENV{'ROX_USE_CYGWIN'} = "FALSE";
} else {
  $ENV{'ROX_USE_CYGWIN'} = "FALSE";
  $osplatform = "unix";
}

#===========================================================================
# Model compiler installation directories (and other significant files).
#===========================================================================
$ENV{'ROX_MC_MAKE_DIR'} = "$root_dir/make";
$ENV{'ROX_MC_ARC_DIR'} = "$root_dir/arc";
$ENV{'ROX_MC_SCHEMA_DIR'} = "$root_dir/schema";
$ENV{'ROX_MC_SQL_DIR'} = "$ENV{'ROX_MC_SCHEMA_DIR'}/sql";
$ENV{'ROX_MC_CLR_DIR'} = "$ENV{'ROX_MC_SCHEMA_DIR'}/colors";
#====================================================================
# Base name components
#====================================================================
$ENV{'ROX_APP_BIN_DIR_NAME'} = "bin";
$ENV{'ROX_APP_SCHEMA_DIR_NAME'} = "schema";
$ENV{'ROX_APP_SQL_DIR_NAME'} = "sql";
$ENV{'ROX_MC_OOA_SCHEMA_FILE'} = "xtumlmc_schema.sql";
$ENV{'OBJ_SUFFIX'} = "o";

my $schema = "$ENV{'ROX_MC_ROOT_DIR'}/$ENV{'ROX_APP_SCHEMA_DIR_NAME'}/$ENV{'ROX_APP_SQL_DIR_NAME'}/$ENV{'ROX_MC_OOA_SCHEMA_FILE'}";
my $arcdir = $ENV{'ROX_MC_ARC_DIR'};

###########################################################################
# Start ReplaceUUIDWithLong.
###########################################################################

# ID to replace the UUID with
# Start at zero and pre-populate the hash with the null UUID so that
# it gets mapped to 0.
$nextInternalUniqueID = 0;
$uuidTable{ '00000000-0000-0000-0000-000000000000' } = $nextInternalUniqueID++;

#
# This is a map <UUID, integer_value> that is used during the replacement of
# UUIDs.  If we have seen the entry before then we retrieve it's  mapped value,
# if we have not then we add an entry to the map and get a new value for the
# UUID.
#
%uuidTable;

#
# This is a regular expression used to match our UUIDs.   The UUIDs we search
# for are expected to look like: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
# Where "x" is a hex digit ([0-9a-fA-F]).
#
$UUID_Pattern = "\"(([0-9a-fA-F]{8}?)-([0-9a-fA-F]{4}?)-([0-9a-fA-F]{4}?)-([0-9a-fA-F]{4}?)-([0-9a-fA-F]{12}?))\"";

#
# Determine the next 32-bit value to use.
#
sub getNextInternalUUID();
sub getNextInternalUUID()
{
    return $nextInternalUniqueID++;
}

#
# This routine searches the input file for patterns matching a UUID and as it
# finds them it replaces them with a 32-bt value.  This 32-bit value is
# obtained from getNextInternalUUID() if the UUID hasn't been seen before, or from
# our id map if it has been seen before.
# This function expects 2 arguments: inputFile, OutputFile
#
sub ReplaceUUIDWithLong($$);
sub ReplaceUUIDWithLong($$)
{
  my $infileName = shift;
  my $outfileName = shift;

  if ( ( $infileName eq "-h" ) or ( $infileName eq "-?" ) or ( $infileName eq "" ) or ( $infileName eq $outfileName ) ) {
    die "
This utility is used to replace UUIDs in a model with ids that can fit in a
32-bit integer.  The format of the UUIDs this utility searches for is:
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Where \"x\" is a hex digit ([0-9a-fA-F]).

usage:    ReplaceUUIDWithLong InputFile OutputFile
          InputFile  :  An input file containing UUIDs to be replaced with
                        values that can be stored in a long (32 bits)
          OutputFile :  An output file in which all UUIDs have been replaced.

          Note: InputFile and OutputFile can not be the same.

example:

ReplaceUUIDWithLong MicrowaveOven.xtuml new_MicrowaveOven.xtuml
  \n\n";
  }

    my $inFile = xtumlmc_open( "<" . $infileName );
    my $outFile = xtumlmc_open( ">" . $outfileName );

    while ( <$inFile> ) {
        $_ = internal_replace_uuid( $_ );
        print $outFile "$_";
    }
}

sub internal_replace_uuid($$);
sub internal_replace_uuid($$)
{
    if ( $_ =~ m/$UUID_Pattern/ )
    {
        my $id;
        if ( exists $uuidTable{ $1 } ) {
            $id = $uuidTable{ $1 };
        } else {
            $id = getNextInternalUUID();
            $uuidTable{ $1 } = $id;
        }

        # Replace the UUID with our smaller id
        $_ =~ s/$UUID_Pattern/$id/;
     }
     return $_;
}

##############################
# End ReplaceUUIDWithLong
##############################

# The following subroutines indirect to routines in File::Copy.
sub xtumlmc_copy($$);
sub xtumlmc_copy($$)
{
  my $src = shift; my $dest = shift;
  copy( $src, $dest ) or die "Could not copy $src to $dest.\n";
}
sub xtumlmc_move($$);
sub xtumlmc_move($$)
{
  my $src = shift; my $dest = shift;
  move( $src, $dest ) or die "ERROR:  Could not move $src to $dest.\n";
}
sub xtumlmc_copy_different($$);
sub xtumlmc_copy_different($$)
{
  my $src = shift; my $dest = shift;
  if ( compare( $src, $dest ) != 0 ) {
    xtumlmc_copy( $src, $dest );
  }
}

# This routine will insulate perl open.
# Use automatic "my" filehandles that politely go out of scope.
sub xtumlmc_open($);
sub xtumlmc_open($)
{
  my $path = shift;
  open( my $fh, $path ) or die "ERROR:  Could not open file $path.\n";
  return $fh;
}
sub xtumlmc_opendir($);
sub xtumlmc_opendir($)
{
  my $path = shift;
  opendir( my $fh, $path ) or die "ERROR:  Could not open directory $path.\n";
  return $fh;
}
sub xtumlmc_mkdir($);
sub xtumlmc_mkdir($)
{
  my $path = shift;
  mkdir( $path ) or die "ERROR:  Could not create directory $path.\n";
}
sub xtumlmc_rmdir($);
sub xtumlmc_rmdir($)
{ # Recursively erase the passed-in directory.
  my $file = shift;
  if ( -f $file ) {
    unlink $file;
  } elsif ( -d $file ) {
    my $DIR = xtumlmc_opendir( $file ); my @entries = readdir $DIR;
    foreach $entry ( @entries ) {
      xtumlmc_rmdir( "$file/$entry" ) if ( $entry ne '.' && $entry ne '..' );
    }
    rmdir $file;
  }
}

#============================================================================
# Remove the specified file.  The argument can be  single file or comma-
# delimited list of files.
#============================================================================
sub xtumlmc_rm($);
sub xtumlmc_rm($)
{
  unlink( shift );
}

#===========================================================================
# Get Windows style path name.
#===========================================================================
sub rox_pwd($);
sub rox_pwd($)
{
  my $conversion = shift;
  my $path = cwd();
  if ( "TRUE" eq $ENV{'ROX_USE_CYGWIN'} ) {
    $path = `cygpath $conversion "$path"`;
  } else {
    if ( "-d" eq $conversion ) {
      # The following two lines provide ActiveState-specific behavior
      # for the compiled executable.  They need to be commented out
      # when running the interpreted version of this script
      #use Win32;
      #$path = Win32::GetShortPathName( $path );
    }
  }
  $path =~ s/(\r|\n)//g;
  return $path;
}

#===========================================================================
# Get the present working directory and process for platform.
#===========================================================================
sub pwd();
sub pwd()
{
  return rox_pwd( "-m" );
}

#===========================================================================
# Convert DOS/Windows style path into Unix style path.
# Do convert on Windows machines.  No need to convert on Solaris.
#===========================================================================
sub rox_path($$);
sub rox_path($$)
{
  my $param = shift;
  my $path = shift;
  # If input path is a directory, cd to it and use pwd.
  # Note!  This is hiding weaknesses in this utility.
  if ( -d $path ) {
    my $curdir = rox_pwd( "-u" );
    chdir $path;
    $path = rox_pwd( $param );
    chdir $curdir;
  } elsif ( "TRUE" eq $ENV{'ROX_USE_CYGWIN'} ) {
    $path =~ s/(\r|\n)//g;
    $path = `cygpath $param "$path"`;
  } else {
    # path not found, do nothing
  }
  $path =~ s/(\r|\n)//g;
  return $path;
}

#=====================================================================
# Output the path variable to the BridgePoint (6.1) bin directory.
#=====================================================================
sub ROX_BridgePointBin();
sub ROX_BridgePointBin()
{
  my $bp_home=ROX_BridgePointHome();
  return $bp_home . "/bin";
}

#=====================================================================
# Output the path variable to the BridgePoint installation.
#=====================================================================
sub ROX_BridgePointHome();
sub ROX_BridgePointHome()
{
  my $new_path = $ENV{'XTUMLMC_HOME'};
  $new_path =~ s/"//g;
  $new_path = rox_path( "-m", $new_path );
  return $new_path;
}

#====================================================================
# Copy default marking files into the build node.
#====================================================================
sub ROX_InstallSystemColorTemplates($);
sub ROX_InstallSystemColorTemplates($)
{
  my $root_node = rox_path( "-m", shift );
  my $app_color_dir=$root_node;
  my $rox_mc_clr_dir = $ENV{'ROX_MC_CLR_DIR'};
  if ((! -f "$app_color_dir/bridge.mark") && (-f "$rox_mc_clr_dir/bridge.mark")) {
    xtumlmc_copy("$rox_mc_clr_dir/bridge.mark","$app_color_dir/bridge.mark");
    chmod 0666,"$app_color_dir/bridge.mark";
  }
  if ((! -f "$app_color_dir/datatype.mark" ) && (-f "$rox_mc_clr_dir/datatype.mark")) {
    xtumlmc_copy("$rox_mc_clr_dir/datatype.mark","$app_color_dir/datatype.mark");
    chmod 0666,"$app_color_dir/datatype.mark";
  }
  if ((! -f "$app_color_dir/system.mark" ) && (-f "$rox_mc_clr_dir/system.mark")) {
    xtumlmc_copy("$rox_mc_clr_dir/system.mark","$app_color_dir/system.mark");
    chmod 0666,"$app_color_dir/system.mark";
  }
  if ((! -f "$app_color_dir/autosar.mark" ) && (-f "$rox_mc_clr_dir/autosar.mark")) {
    xtumlmc_copy("$rox_mc_clr_dir/autosar.mark","$app_color_dir/autosar.mark");
    chmod 0666,"$app_color_dir/autosar.mark";
  }
  if ((! -f "$app_color_dir/sys_functions.arc" ) && (-f "$rox_mc_clr_dir/sys_functions.arc")) {
    xtumlmc_copy("$rox_mc_clr_dir/sys_functions.arc","$app_color_dir/sys_functions.arc");
    chmod 0666,"$app_color_dir/sys_functions.arc";
  }
}

#===========================================================================
# Create the Single Directory Environment (SDE).
#===========================================================================
sub xtumlmc_sde_init($);
sub xtumlmc_sde_init($)
{
  my $root_node = rox_path( "-m", shift );
  $root_node =~ s/(\r|\n)//g;
  my $sde_node = "$root_node/_ch";

  $ENV{'TARGET_MECH_DIR'} = "";
  $ENV{'OBJECTS_LIST'} = "\$(USER_OBJ_TARGETS)";
  if ( $ENV{'ROX_MC_TARGET_COMPILER'} eq "YCH8" ) {
    $OBJ_SUFFIX = "obj";
    $TARGET_MECH_DIR = "H8";
  }
  if ( $ENV{'ROX_MC_TARGET_COMPILER'} eq "exeGCC-CQ" ) {
    $TARGET_MECH_DIR = "SH1";
    $OBJECTS_LIST = "";
  }

  # Create/update the necessary directory structures
  SDE_createNode( $root_node, $sde_node );

  # Create Makefile
  my $str = SDE_createMakefile( $root_node, $sde_node );
  my $FILE1 = xtumlmc_open( ">$sde_node/Makefile" );
  print $FILE1 $str;

  # Create objects.lst
  my $str2 = SDE_createObjectsList( $root_node, $sde_node );
  my $FILE2 = xtumlmc_open( ">$sde_node/object\.lst" );
  print $FILE2 $str2;
}

#=====================================================================
# SDE_copyMechFiles
#=====================================================================
sub SDE_copyMechFiles($$$);
sub SDE_copyMechFiles($$$)
{
  my $des_dir = shift;
  my $src_dir = shift;
  my $file_type = shift;

  # chdir $src_dir;
  my $DIR = xtumlmc_opendir( $src_dir );
  my @entries = readdir $DIR;
  my @filtered_entries = grep{/\.$file_type/i} @entries;
  foreach my $i ( @filtered_entries ) {
    if ( ! -f $des_dir/$i ) {
      if ( $i !~ m/tim_bridge.h/i ) {
        if ( $i !~ m/tim_bridge.c/i ) {
          xtumlmc_copy( "$src_dir/$i","$des_dir/$i" );
        }
      }
    }
  }
}

#=====================================================================
# SDE_createNode
#=====================================================================
sub SDE_createNode($$);
sub SDE_createNode($$)
{
  my $root_node = shift;
  my $sde_node = shift;

  $sde_node =~ s/(\r|\n)//g;
  # create sde node
  if ( ! -d $sde_node ) {
    xtumlmc_mkdir( $sde_node );
  }

  #copy all necessary mech files depending on target
  if ( -d "$ENV{'ROX_MC_ROOT_DIR'}/mech/target/$ENV{'TARGET_MECH_DIR'}/source" ) {
    SDE_copyMechFiles( $sde_node, "$ENV{'ROX_MC_ROOT_DIR'}/mech/target/$ENV{'TARGET_MECH_DIR'}/source", "c" );
    SDE_copyMechFiles( $sde_node, "$ENV{'ROX_MC_ROOT_DIR'}/mech/target/$ENV{'TARGET_MECH_DIR'}/source", "asm" );
    SDE_copyMechFiles( $sde_node, "$ENV{'ROX_MC_ROOT_DIR'}/mech/target/$ENV{'TARGET_MECH_DIR'}/include", "h" );
    SDE_copyMechFiles( $sde_node, "$ENV{'ROX_MC_ROOT_DIR'}/mech/target/$ENV{'TARGET_MECH_DIR'}/obj", "$ENV{'OBJ_SUFFIX'}" );
  }
}

#===========================================================================
# List files in given directory with given suffix.
#===========================================================================
sub GetSourceFileList($$);
sub GetSourceFileList($$)
{
  my $src_path = shift;
  my $type = shift;

  my $DIR = xtumlmc_opendir( $src_path );
  my @entries = readdir $DIR;
  my @filtered_entries = grep( /\.$type/i, @entries );
  return @filtered_entries;
}

#===========================================================================
# Create the makefile for the single directory environment.
#===========================================================================
sub SDE_createMakefile($$);
sub SDE_createMakefile($$)
{
  my $root_node = shift;
  my $sde_node = shift;

  $root_node =~ s/(\r|\n)//g;
  my @source_file_set = GetSourceFileList( $sde_node, "c" );
  my $num_src_files = @source_file_set;
  if ( 0 < $num_src_files ) {
    my $DIR = xtumlmc_opendir( $sde_node );
    my @entries = readdir $DIR;
    my @filtered_entries = grep{/\.(c|cc|cpp|h|hh|hpp)$/i} @entries;
    $num_src_files = @filtered_entries;
  }

  # All files we need to muck with...
  my @total_file_set = @source_file_set;
  my $num_total_files = $num_src_files;

  my $makefile =<<'##makefile##';
#=============================================================================
# File: Makefile
#
# Warnings:
#   !!! THIS IS AN AUTO-GENERATED FILE. PLEASE DO NOT EDIT. !!!
#=============================================================================

.POSIX:
.SCCS_GET:

# Displays the available targets in tabular format.
help :
    @echo "============================================================"
    @echo " Primary Targets       | Compile     Link"
    @echo "============================================================"
    @echo "   all                 |   YES        YES"
    @echo "   comp_src            |   YES         NO"
    @echo "   link_sys            |   YES        YES"
    @echo "   clean               |   "
    @echo "============================================================="

include root_node/Makefile.in
include root_node/Makefile.user

# use Target C Cross Compiler
CMD_TARGET_COMPILE    = ${CMD_COMPILE}
CMD_TARGET_ASSEMBLE   =
CMD_TARGET_PREPROCESS =
CMD_TARGET_LINK       = ${CMD_LINK}

# Relative paths for object and source files.
SRC_PATH=
OBJ_PATH=
##makefile##

  my $makefile_part2 =<< '##makefile_p2##';
#=============================================================================
# List of all object files to be compiled.
#=============================================================================
##makefile_p2##

  if ( $num_src_files > 0 ) {
    $makefile_part2 .= "USER_OBJ_TARGETS = \\\n";
  } else {
    $makefile_part2 .= "USER_OBJ_TARGETS =\n";
  }

  if ( $num_total_files > 0 ) {
    my $file_count = 0;
    foreach my $temp_file ( @total_file_set ) {
      $file_count++;
      my $object_file = "";
      my $this_file = $temp_file;
      if ( $this_file =~ m/\.c/ ) {
        $this_file =~ s/\.c//;
        $object_file = "$this_file\.$ENV{'OBJ_SUFFIX'}";
      } else {
        die "$program: Unknown target file type -> $this_file\n";
      }
      if ( $file_count < $num_total_files ) {
        $makefile_part2 = $makefile_part2."\t\${OBJ_PATH}$object_file \\\n";
      } else {
        $makefile_part2 = $makefile_part2."\t\${OBJ_PATH}$object_file\n";
      }
    }
  }
  $makefile_part2 .= "\n";

  my $makefile_part3 = "";
  my $makefile_part4 = "";
  if ( $num_src_files > 0 ) {
    $makefile_part3 = << '##makefile_part3##';
#=============================================================================
# Source file target recipes.
#=============================================================================
##makefile_part3##
    foreach $temp_file(@source_file_set) {
        my $source_file = $temp_file;
        $source_file =~ s/\.c//;
        $object_file="$source_file.$ENV{'OBJ_SUFFIX'}";
        $makefile_part3 = $makefile_part3."\${OBJ_PATH}$object_file : \${SRC_PATH}$temp_file\n";
        $makefile_part3 = $makefile_part3."\t\${CMD_TARGET_COMPILE}\n";
        $makefile_part3 = $makefile_part3."\t\${CMD_TARGET_ASSEMBLE}\n";
        $makefile_part3 = $makefile_part3."\n";
    }

  }

  $makefile_part4 =<< '##makefile_part4##';
#=============================================================================
# Build environment targets.
#=============================================================================
# Clean out compiled object files.
clean :
    @'rm' -f ${OBJ_PATH}*.OBJ_SUFFIX

# Target for compiling objects.
comp_src : ${USER_OBJ_TARGETS}

# Target for link system.
link_sys : ${USER_OBJ_TARGETS}
    $(CMD_TARGET_LINK) OBJECTS_LIST

all : comp_src link_sys
##makefile_part4##

my $complete_makefile = $makefile.$makefile_part2.$makefile_part3.$makefile_part4;
$complete_makefile =~ s/root_node/$root_node/g;
$complete_makefile =~ s/OBJECTS_LIST/$ENV{'OBJECTS_LIST'}/g;
$complete_makefile =~ s/OBJ_SUFFIX/$ENV{'OBJ_SUFFIX'}/g;
return $complete_makefile;
}

#=====================================================================
# Create the list of objects for linking.
#=====================================================================
sub SDE_createObjectsList($$);
sub SDE_createObjectsList($$)
{
  my $root_node = shift;
  my $sde_node = shift;

  my $num_src_files = 0;
  my @source_file_set = GetSourceFileList( $sde_node, "c" );
  if ( 0 < @source_file_set ) {
    my $DIR = xtumlmc_opendir( $sde_node );
    my @entries = readdir $DIR;
    $num_src_files = grep( /$\.c/i, @entries );
  }

  # all files we need to work with

  my @object_list;
  foreach my $file ( @source_file_set ) {
    if ( $file =~ m/\.c/ ) {
      $file =~ s/\.c.*/$ENV{'OBJ_SUFFIX'}/;
      @object_list = ( @object_list, $file );
    } else {
      die "$program:  Unknown target file type -> $file\n";
    }
  }
  return @object_list;
}

#=====================================================================
# Run gen_erate.
#=====================================================================
sub xtumlmc_gen_erate($);
sub xtumlmc_gen_erate($)
{
  my @param_list = @_;
  my $pt_home = ROX_BridgePointHome();
  $ENV{'PT_LOG_DIR'} = "$pt_home/log_dir";
  my $dos_or_unix = add_to_path( "$pt_home/$mc/bin" );
  my $rval = 0;
  if ( "win32" eq "$osplatform" ) {
    $rval = system( "gen_erate.exe @param_list" );
  } else {
    # If we are running on linux, see if the new python generator 
    # is in place.  If it is, use it.  Otherwise use the old one.
    my $gen_pyz = "$ENV{'ROX_MC_BIN_DIR'}/gen_erate.pyz";
    if ( -f $gen_pyz ) {
      # Passing the output (here $pypy_cmd) as the command
      # causes the pypy interpreter to run rather than executing 
      # gen_erate.pyz. Calling it this way allows generator to run. 
      $pypy_cmd = `which pypy`;
      if ( $pypy_cmd ne "" ) {
        $pypy = "pypy";
      }
      $rval = system( "$pypy $gen_pyz @param_list" );
    } else {
      $gencmd = "wine $ENV{'ROX_MC_BIN_DIR'}/gen_erate.exe";
      $rval = system( "$gencmd @param_list" );
    }
  }

  return $rval;
}

#=====================================================================
# Run gen_import.
#=====================================================================
sub xtumlmc_gen_import($$);
sub xtumlmc_gen_import($$)
{
  my $gen_database_file = shift; my $sql_file = shift;
  my $gencmd = ROX_BridgePointBin() . "/pt_gen_import";
  return system( "$gencmd -q $gen_database_file $sql_file 2>&1" );
}

#=====================================================================
# Run gen_file.
#=====================================================================
sub xtumlmc_gen_file($$);
sub xtumlmc_gen_file($$)
{
  my $gen_database = shift; my $archetype = shift;
  my $gencmd = ROX_BridgePointBin() . "/pt_gen_file";

  # Save gen_files status so successful rm doesn't hide erros.
  my $retvalue = system( "$gencmd -q $gen_database $archetype 2>&1" );

  # Clean up temporary files
  unlink "____actn.arc" if ( -f "____actn.arc" );
  unlink "____file.txt" if ( -f "____file.txt" );
  return $retvalue;
}

#=====================================================================
# Initialize the build/generation workspace for 3020.
#=====================================================================
sub xtumlmc_init_workspace_3020($$);
sub xtumlmc_init_workspace_3020($$)
{
  my $first_entry = shift;
  my $second_entry = shift;
  my $program = "xtumlmc_init_workspace_3020";

  if ( $first_entry eq "-h" ) {
    die "
       Usage: $program ( (app_root_dir) executable_name )
       app_root_dir    : application root directory
       executable_name : executable to be generated\n";
  }

  my $app_root_dir = "";
  my $executable_name = "";
  my $build_spec = "";
  my $root_node = "";

  # Get translation root directory
  $app_root_dir = $first_entry;

  # Get the generated executable name
  $executable_name = $second_entry;

  $app_root_dir_exists = "false";

  if ( $app_root_dir eq "" ) {
    print "Enter the pathname to the directory in which you wish to translate:";
    my $app_root_dir = <STDIN>;
    chomp($app_root_dir);
    if ( $app_root_dir eq "" ) {
      die "
ERROR:  Translation node directory pathname not specified.

Usage:  $program ( (app_root_dir) executable_name )
  app_root_dir    : application root directory
  executable_name : executable to be generated\n";
    }
  }

  if ( ! -d $app_root_dir ) {
    print "Creating application node:  $app_root_dir\n";
    mkpath( $app_root_dir );
  } else {
    print "Upgrading translation workspace:  $app_root_dir\n";
    $app_root_dir_exists = "true";
  }

  $root_node = rox_path( "-m", $app_root_dir );
  if ( $root_node =~ /\s/ ) {
    $root_node = rox_path( "-d", $app_root_dir );
  }
  $ENV{'ROX_APP_ROOT_DIR'} = $root_node;  # export for following scripts
  ROX_InstallSystemColorTemplates( $root_node );

  if ( $app_root_dir_exists eq "false" ) {
    print "Application translation node successfully installed!\n";
  }
  return 0;
}

#=====================================================================
# Add to the system path
#=====================================================================
sub add_to_path($);
sub add_to_path($)
{
  my $new = shift;
  if ( $ENV{'PATH'} =~ /;/ ) {
    $new = rox_path( "-m", $new );
    $ENV{'PATH'} .= ";$new";
    return "dos";
  } else {
    $new = rox_path( "-u", $new );
    $ENV{'PATH'} .= ":$new";
    return "unix";
  }
}

#---------------------------------------------------------------------------
# Cleanse all elements from the specified subsystems from a model.
#
# usage: xtumlmc_cleanse_inserts <source> <destination> <[NAME1] [NAME2] [...]>
# where:
#    NAME<x> = A class name or prefix.  For example: "ACT_" would remove all
#              inserts that begin with "ACT_" (everything in the action subsystem).
#              "GD_MD" would remove all inserts into the "GD_MD" class.
#---------------------------------------------------------------------------
sub xtumlmc_cleanse_inserts($$$);
sub xtumlmc_cleanse_inserts($$$)
{
  my $I = xtumlmc_open( "<" . shift );
  my $O = xtumlmc_open( ">" . shift );
  MCJAVAOUTER: while ( <$I> ) {
    if ( /^INSERT INTO / ) {
      # If this element is one of the excluded, exclude it.
      foreach $subsystem_prefix (@_) {
        if ( /^INSERT INTO $subsystem_prefix/ ) {
          if ( /^INSERT INTO .*_PROXY/ ) {
            while ( <$I> ) { if ( /^\s+'.*\.xtuml'\);/ ) { next MCJAVAOUTER; } }
          } else {
            while ( <$I> ) { if ( /^.*[;]\s*$/ ) { next MCJAVAOUTER; } }
          }
        }
      }
      print $O "$_";
      next MCJAVAOUTER;
    } else {
      # Just a normal line, send it on through.
      print $O "$_";
    }
  }
}

#---------------------------------------------------------------------------
# This routine is called from the BrigePoint build scripts to pre-process
# the model before it is passed to MC-Java/gen_erate.  It is responsible for
# stripping PEI data from the model, replacing UUID values with longs, and
# converting the model from muli-file to single-file.
# It usage is the same as xtumlmc_cleanse_inserts.
#---------------------------------------------------------------------------
sub xtumlmc_cleanse_for_BridgePoint($$);
sub xtumlmc_cleanse_for_BridgePoint($$)
{
  my $input_path = shift;

  # If the first argument is -u, handle the UUID seed argument 
  if ( $input_path eq '-u' ) { 
      $nextInternalUniqueID = shift; 
      $input_path = shift;
  }
  $SF_Out = xtumlmc_open( ">" . shift );
  @ClassesToRemove = @_;

  # Recurse through the given directory calling the internal function on 
  # each file. The sort makes sure we are consistent in processing order.
  find( {
    preprocess => sub { return sort @_ },
    wanted => \&internal_cleanse_for_bp,
  }, $input_path);

  close($SF_Out);
}

sub internal_cleanse_for_bp($$);
sub internal_cleanse_for_bp($$)
{
  if ( /\.xtuml$/ ) {
    my $I = xtumlmc_open( "<" . $_ );

    MCJAVAOUTER: while ( <$I> ) {
      if ( /^INSERT INTO / ) {
        # Remove proxys
        if ( /^INSERT INTO .*_PROXY/ ) {
          while ( <$I> ) { if ( /^\s+'.*\.xtuml'\);/ ) { next MCJAVAOUTER; } }
        }

        # If this element is one of the excluded remove it
        foreach $subsystem_prefix (@ClassesToRemove) {
          if ( /^INSERT INTO $subsystem_prefix/ ) {
            while ( <$I> ) { if ( /.+\);\s*/ ) { next MCJAVAOUTER; } }
          }
        }

        $_ = &internal_replace_uuid( $_ );

        print $SF_Out "$_";
        next MCJAVAOUTER;
      } else {
        # Just a normal line, send it on through.
        $_ = &internal_replace_uuid( $_ );
        print $SF_Out "$_";
      }
    }
  }
}

#---------------------------------------------------------------------------
# Parse through the model removing graphics elements and proxy statements,
# handle inline blocks in action language.
#---------------------------------------------------------------------------
sub xtumlmc_cleanse_model($$$);
sub xtumlmc_cleanse_model($$$)
{
  my $I = xtumlmc_open( "<" . shift );
  my $O = xtumlmc_open( ">" . shift );
  my $stripNonAscii = shift || 'false';
  my $v_lst = 0;

  OUTER: while ( <$I> ) {
    if ( $stripNonAscii eq 'true' ) {
      # A note about this substitution... It reads characters (UTF-8 chars, not
      # simply bytes).  The ord(EXPR) function "Returns the numeric value of the 
      # first character of EXPR)".  So, read a character, put it into $1, then
      # evaluate if it is ASCII (value less than 128). If it is, just put the
      # character back down.  If it is not, put the ASCII string "c<hex value>" 
      # in it's place.
      s/(.)/ord($1) < 128 ? $1 : sprintf("c%X", ord($1))/ge;
    }
    # NOTE: We must convert C-Style comments in OAL to C++-style in case the 
    # user has MarkStateActionCommentBlocksEnabled turned on.  That way we 
    # won't have OAL C-style comments inside the output code's C-Style 
    # function comment blocks.
    if ( /\/\// ) {
      # Handle a C++-style comment. If a C-style end comment is inside this 
      # line, replace it with a space, otherwise just output the original line.
      my $pre = $`;
      my $post = $';
      my $line = $_;
      if ( $line =~ /\*\// ) {
        $post =~ s/\*\// /g;
        print $O "$pre//$post"; 
      } else {
        print $O "$line";
      }
    } elsif ( /\/\*(.*)\*\// ) {
      # Handle a line one-line C-style comment
      print $O "$`//$1\n";
      my $post = $'; chop($post);
      if ( $post ne "" ) { print $O "$post\n"; }
    } elsif ( /\/\*/ ) {
      # We've started a multi-line comment block. Change lines to
      # C++-style comments
      print $O "$`//$'";
      while ( <$I> ) {
        if ( $stripNonAscii eq 'true' ) {
          s/(.)/ord($1) < 128 ? $1 : sprintf("c%X", ord($1))/ge;
        }
        if ( /\*\// ) {
          print $O "// $`";
          if ( $' ne "" ) { print $O "\n$'"; }
          next OUTER;
        } else {
          print $O "// $_";
        }
      }
    } elsif ( /^INSERT INTO / ) {
      # A new element has been encountered.  
      # If this element is for a graphic or proxy, remove it
      # To get this list run the xtumlmc_schema.sql file through:
      # awk '/CREATE TABLE/{ print $3 }' | sed "s/_.*/_/" | sort | uniq
      if ( ! ( ( /^INSERT INTO ACT_/ ) ||
                ( /^INSERT INTO A_/ ) ||
                ( /^INSERT INTO CL_/ ) ||
                ( /^INSERT INTO CNST_/ ) ||
                ( /^INSERT INTO COMM_/ ) ||
                ( /^INSERT INTO C_/ ) ||
                ( /^INSERT INTO EP_/ ) ||
                ( /^INSERT INTO E_/ ) ||
                ( /^INSERT INTO IA_/ ) ||
                ( /^INSERT INTO I_/ ) ||
                ( /^INSERT INTO L_/ ) ||
                ( /^INSERT INTO MSG_/ ) ||
                ( /^INSERT INTO O_/ ) ||
                ( /^INSERT INTO PA_/ ) ||
                ( /^INSERT INTO PE_/ ) ||
                ( /^INSERT INTO RV_/ ) ||
                ( /^INSERT INTO R_/ ) ||
                ( /^INSERT INTO SM_/ ) ||
                ( /^INSERT INTO SPR_/ ) ||
                ( /^INSERT INTO SQ_/ ) ||
                ( /^INSERT INTO S_/ ) ||
                ( /^INSERT INTO TE_/ ) ||
                ( /^INSERT INTO TM_/ ) ||
                ( /^INSERT INTO UC_/ ) ||
                ( /^INSERT INTO V_/ )
           ) ) {
        while ( <$I> ) { 
          if ( /^.*[;]\s*$/ ) { next OUTER; }
        }
      }

      # If this element is a proxy, remove it
      if ( /^INSERT INTO .*_PROXY/ ) {
        while ( <$I> ) { if ( /^\s+'.*\.xtuml'\);$/ ) { next OUTER; } }
      }

      # If this element is a V_LOC, remove it
      if ( /^INSERT INTO V_LOC/ ) {
        while ( <$I> ) { if ( /^.*[;]\s*$/ ) { next OUTER; } }
      }

      if ( /^INSERT INTO V_LST/ ) { $v_lst = 1; }
      print $O "$_";
      next OUTER;
    } else {
      if ( $v_lst && /\'docbook\/t\..*\.xml\'/ ) { s/.xml/.h/; $v_lst = 0; }
      # Substitute triple-tick with single-tick but only when something is inside.
      s/'''([a-zA-Z0-9_ ]+)'''/'\1'/g;
      # Just a normal line, send it on through.
      print $O "$_";
    }
  }

}

#-----------------------------------------------------------------------------
# Concatenate the specifed input file to the specifed output file.
#-----------------------------------------------------------------------------
sub xtumlmc_concat($$);
sub xtumlmc_concat($$)
{
  my $I = xtumlmc_open( "<" . shift );
  my $O = xtumlmc_open( ">>" . shift );
  while ( <$I> ) {
    print $O "$_";
  }
}


sub ConvertMultiFileToSingleFile($$);
sub ConvertMultiFileToSingleFile($$)
{
  my $input_path = shift;
  my $SingleFileOutputName = shift;
  $SF_Out = xtumlmc_open( ">>" . $SingleFileOutputName );

  find( \&modelFinderCallback, $input_path );

  close($SF_Out);
}

#-----------------------------------------------------------------------------
# This is a callback routine used in ConvertMultiFileToSingleFile.
# This rountine looks to see if the file passed-in is a ".xtuml" file and if
# it is it strips the proxies from it and concatenates it into
# $SF_Out (which is defined in ConvertMultiFileToSingleFile()).
#-----------------------------------------------------------------------------
sub modelFinderCallback($$);
sub modelFinderCallback($$)
{
  if ( /\.xtuml$/ ) {
    my $I = xtumlmc_open( "<" . $_ );

    FINDOUTER: while ( <$I> ) {
      # If this element is a proxy, remove it
      if ( /^INSERT INTO .*_PROXY/ ) {
        while ( <$I> ) { if ( /^\s+'.*\.xtuml'\);/ ) { next FINDOUTER; } }
      }

      print $SF_Out "$_";
      next FINDOUTER;
    }
  }
}

#---------------------------------------------------------------------------
# Run referential integrity checking on the input models (projects).
#---------------------------------------------------------------------------
sub xtuml_integrity;
sub xtuml_integrity
{
  my $usage = "Usage:\n\txtuml_integrity -i <model folder or file1> [-i <another folder or file>] [-g] [-m <accumulated model data file>] [-o <report file>]\n";

  # get command line arguments
  my @param_list = @_;

  # set the path
  my $current_path = $ENV{'PATH'};
  my $mc_bin_dir = abs_path( dirname($0) );
  add_to_path( $mc_bin_dir );

  my @tt = localtime();
  my $serial = "$tt[5]$tt[4]$tt[6]$tt[2]$tt[1]_$$";

  # input variables
  my @inputs;
  my $skip_globals = 0;
  my $model_file = "xtuml_integrity_model_file_${serial}";
  my $out_file = ""; # if not out_file, use STDOUT

  my $delete_model_file = 1; # Default to deleting accumulated model file when not supplied on command line.
  my $tmp_file1 = "xtuml_integrity_temp1_${serial}";

  # parse arguments
  my $directive = "";
  foreach my $arg(@param_list) {
    if ( $arg eq "-i" or $arg eq "-o" or $arg eq "-m" ) {   # set the directive
      $directive = "$arg";
    } elsif ( $arg eq "-g" ) {                              # skip globals
      $directive = "$arg";
      $skip_globals = 1;
    } elsif ( $directive eq "-i" ) {                        # add an input
      push @inputs, $arg;
    } elsif ( $directive eq "-m" ) {                        # denote accumulation file
      $model_file = "$arg";
      $delete_model_file = 0;
    } elsif ( $directive eq "-o" ) {                        # save report to file
      $out_file = "$arg";
    } else {
      print STDERR $usage;
      exit 1;
    }
  }

  # Check if we have any models to interrogate.
  if ( !@inputs ) {
    print STDERR $usage;
    exit 1;
  }

  # Get the global native types.
  if ( !$skip_globals ) {
    push @inputs, glob("$mc_bin_dir/../../../plugins/org.xtuml.bp.pkg*/globals/Globals.xtuml");
  }

  # Accumulate model data.
  foreach $i (@inputs) {
    &ConvertMultiFileToSingleFile ( $i, $tmp_file1 );
  }

  # Filter graphics and proxy entries and non-ASCII characters from the model file.
  &xtumlmc_cleanse_model( $tmp_file1, $model_file, 'true' );

  # Run the check referential integrity binary.
  if ( "" eq $out_file ) {
    system( "integrity $model_file" );
  } else {
    system( "integrity $model_file > $out_file" );
  }

  # Remove the temporary files.
  xtumlmc_rm( $tmp_file1 );
  if ( $delete_model_file ) {
    xtumlmc_rm( $model_file );
  }
}

#---------------------------------------------------------------------------
# Export a BridgePoint model to MASL
#---------------------------------------------------------------------------
sub xtuml2masl;
sub xtuml2masl
{
  # xtuml2masl [-v | -V] [-e] [-xf] [-xl] -i <eclipse project> -d <domain component> [-o <output directory>]
  # xtuml2masl [-v | -V] [-e] [-xf] [-xl] -i <eclipse project> -p <project package> [-o <output directory>]

  # get command line arguments
  my @param_list = @_;

  # set the path
  my $current_path = $ENV{'PATH'};
  my $masl_bin_dir = $ENV{'MASL_BIN_DIR'};
  $ENV{'PATH'} = "$masl_bin_dir:$current_path";

  # input variables
  my $validate = "";
  my $eclipse = "";
  my $out_dir = "";
  my $skip_formatter = "";
  my $skip_action_language = "";

  my @inputs;
  my $num_inputs = -1;
  my @num_dom;
  my @num_proj;

  my @dom_names;
  my @proj_names;

  my $usage = "Usage:\n\txtuml2masl [-v | -V] [-e] [-xf] [-xl] -i <eclipse project> -d <domain component> [-o <output directory>]\n\txtuml2masl [-v | -V] [-e] [-xf] [-xl] -i <eclipse project> -p <project package> [-o <output directory>]\n";

  # parse arguments
  my $directive = "";
  foreach my $arg(@param_list) {
    if ( ( $arg eq "-v" or $arg eq "-V" ) and $validate eq "" ) {   # if we encounter a validate flag, set the validation
      $validate = "$arg";
      $directive = "";                                              # encountering a validation flag resets the directive because
    }
    elsif ( $arg eq "-e" and $eclipse eq "" ) {                     # if we encounter eclipse flag
      $eclipse = "$arg";
      $directive = "";
    }
    elsif ( $arg eq "-xf" and $skip_formatter eq "" ) {               # if we encounter flag indicating skip MASL formatting
      $skip_formatter = "$arg";
      $directive = "";
    }
    elsif ( $arg eq "-p" or $arg eq "-d" or $arg eq "-i" or $arg eq "-o" ) {        # set the directive
      $directive = "$arg";
    }
    elsif ( $arg eq "-xl" and $skip_action_language eq "" ) {         # if we encounter flag indicating skip output of MASL activities
      $skip_action_language = "-s";
      $directive = "";
    }
    elsif ( $directive eq "-i" ) {                                  # add an input
      $num_inputs++;
      push @inputs, $arg;
      $num_dom[$num_inputs] = 0;
      $num_proj[$num_inputs] = 0;
    }
    elsif ( $directive eq "-p" ) {                                   # add a project name
      if ( $num_inputs >= 0 ) {
        push @proj_names, $arg;
        $num_proj[$num_inputs]++;
      }
    }
    elsif ( $directive eq "-d" ) {                                  # add a domain name
      if ( $num_inputs >= 0 ) {
        push @dom_names, $arg;
        $num_dom[$num_inputs]++;
      }
    }
    elsif ( $directive eq "-o" and $out_dir eq "" ) {                # only can set the output directory once
      $out_dir = "$arg";
    }
    else {
      print STDERR $usage;
      exit 1;
    }
  }

  # check if we have any projects or domains to convert
  if ( !@inputs || ( !@proj_names && !@dom_names ) ) {
    print STDERR $usage;
    exit 1;
  }

  print STDERR "Initializing export...\n";

  # if no out directory was given, give the current working directory
  if ( $out_dir eq "" ) { $out_dir = "."; }

  # make the output directory if there is one
  use File::Path qw(make_path);
  eval { make_path("$out_dir") };
  if ($@) {
    print STDERR "-xtuml2masl: ERROR could not create directory '$out_dir'\n";
    exit 1
  }

  # if the eclipse flag is not set, run the pre-builder
  if ( $eclipse eq "" ) {
    print STDERR "Invoking BridgePoint pre-builder...\n";
    # the WORKSPACE env variable is expected to be set properly
    my ($volume, $directory, $file) = File::Spec->splitpath(__FILE__);
    foreach my $inproj (@inputs) {
      my $proj = basename($inproj);
      system( "$directory/CLI.sh Build -prebuildOnly -doNotParse -project $proj " );
    }
  }

  # process command
  my $c = 0;
  my $doff = 0;
  my $poff = 0;
  foreach $i (@inputs) {
    my $command = "";
    for ( my $k = 0; $k < $num_dom[$c]; $k++ ) {
      $command = "$command -d$dom_names[$k+$doff]";
    }
    $doff += $num_dom[$c];
    for ( my $k = 0; $k < $num_proj[$c]; $k++ ) {
      $command = "$command -p$proj_names[$k+$poff]";
    }
    $poff += $num_proj[$c];
    $c++;

    # cleanse the prebuilder output
    system( "cat $i/gen/code_generation/*.sql > $i/gen/code_generation/z.xtuml" );
    &xtumlmc_cleanse_for_BridgePoint ( "$i/gen/code_generation/z.xtuml", "$i/gen/code_generation/a.xtuml", "GD_", "DIM_" );

    # call the utilities
    # Note: Add the -k option here to x2m to specify that key letter  
    # pragmas should be produced by the exporter. By default the -k 
    # option is not used in order to suppress generation of "key_letter"
    # pragmas.
    my $sys_cmd = "cat $i/gen/code_generation/a.xtuml | x2m $skip_action_language -i$i $command | tee $i/gen/code_generation/x2m_output.txt | tr -d '\15\32' | wasl $validate $skip_action_language -i$i $command -o$out_dir | tee $i/gen/code_generation/asl_output.txt ";
    print STDERR "$sys_cmd\n";
    system( $sys_cmd );

    # clean up
    unlink "$i/gen/code_generation/z.xtuml";
    unlink "$i/gen/code_generation/a.xtuml";
  }

  if ( "no" eq "" ) {
    # format MASL
    my $masl_format_cp = join(":", glob("$masl_bin_dir/*.jar"));
    opendir my $dh, $out_dir
      or die "$0: opendir: $!";
    while (defined(my $format_dir = readdir $dh)) {
      next unless -d "$out_dir/$format_dir";
      if ( $format_dir ne "." and $format_dir ne ".." ) {
        move( "$out_dir/$format_dir", "$out_dir/$format_dir.orig");
        my $format_cmd = "java -cp $masl_format_cp MaslFormatter -r -i $out_dir/$format_dir.orig -o $out_dir/$format_dir";
        print STDERR "$format_cmd\n";
        system( $format_cmd );
        # if formatting succeeds, remove the original MASL
        # if not, move the unformatted back to the output dir
        if ($? == 0) {
            rmtree("$out_dir/$format_dir.orig");
        }
        else {
            rmtree("$out_dir/$format_dir");
            move( "$out_dir/$format_dir.orig", "$out_dir/$format_dir");
        }
      }
    }
  }

  print STDERR "Done.\n";

}

#---------------------------------------------------------------------------
# Show function usage.
#---------------------------------------------------------------------------
sub usage();
sub usage()
{
  my $str =<<'##usage##';
usage:    xtumlmc_build -d <dir> -o <model> -s <f.xtuml> -r <EE> -x <xml> -p <pkg> -f file -f file ...
          dir     :  build directory name
          model   :  domain model name within the xtUML SQL file
          f.xtuml :  file containing SQL inserts
          xml     :  XML data representing the preexisting instances (PEIs)
          file    :  marking file(s), source files and include files and
                     other files required in a build
          pkg     :  The fully-qualifed name of the file that holds a list of
                     input package names.
          2       :  using MC-2020
          3       :  using MC-3020 (default)
          e       :  called from eclipse
          O       :  output source directory for copying
          b       :  MC-2020 build specification (default is vc)
          c       :  perform compile step
          g       :  generate XML file for model debugger
          u       :  UUID seed number to start at, defaults to 0 if not specified

example:

xtumlmc_build -c -g -d a1 -o a -s a.sql -r UI -f bridge.mark -o e -s e.sql -f e_domain.mark -f link_sys

alt usage:  xtumlmc_build <internal function name>

example:    xtumlmc_build xtumlmc_gen_erate -nopersist -import a.sql -import b.sql -arch c.arc

##usage##
  print STDERR $str;
}

#
#
#
sub determineBuildFileType($);
sub determineBuildFileType($)
{
    my $optarg = shift;
    if ($optarg =~ /(bridge|datatype|system|autosar)\.mark/ ) {
      @system_mark = ( @system_mark, $optarg );
    } elsif ( $optarg =~ /\.mark/ ) {
      @mark = ( @mark, $optarg );
      if ( $optarg =~ /_/ ) {
        @s = split( "_(domain|class|event)", $optarg );
        @ooas = ( @ooas, $s[0] );
      }
    } elsif ( $optarg =~ /(sys_functions\.arc|dom_functions\.arc|populate\.arc)/ ) {
      @mark = ( @mark, $optarg );
    } elsif ( $optarg =~ /\.sql/ ) {
      @sqls = ( @sqls, $optarg );
    } elsif ( $optarg =~ /\.(c|cc|cpp|cxx)$/i ) {
      @c_files = ( @c_files,$optarg );
    } elsif ( $optarg =~ /\.(h|hh|hpp|hxx)$/i ) {
      @h_files = ( @h_files, $optarg );
    } elsif ( $optarg =~ /Makefile/ ) {
      @make_files = ( @make_files, $optarg);
    } elsif ( $optarg =~ /link_sys/ ) {
      @link_sys = ( @link_sys, $optarg );
    } elsif ( $optarg =~ /\.arc$/ ) {
      @arcs = ( @arcs, $optarg );
    }
}

#---------------------------------------------------------------------------
# Check for request for help on the command line.
#---------------------------------------------------------------------------
if ( 1 > @ARGV ) {
  usage();
  die "exiting...\n";
}
if ( 0 < @ARGV ) {
  if ( $ARGV[0] eq "-h" ) {
    usage();
    exit 0;
  }
}


#=====================================================================
#=====================================================================
#
# xtumlmc_utility MAIN:
#
#=====================================================================
#=====================================================================

#
# There routines are "published" for execution by calling xtumlmc_build
# and passing the name of the routine as the first argument.
#
my %xtumlmc_utility_routines = (
  "xtuml2masl" => TRUE,
  "xtumlmc_gen_erate" => TRUE,
  "xtumlmc_gen_file" => TRUE,
  "xtumlmc_gen_import" => TRUE,
  "xtumlmc_init_workspace_3020" => TRUE,
  "xtumlmc_sde_init" => TRUE,
  "ReplaceUUIDWithLong" => TRUE,
  "ConvertMultiFileToSingleFile" => TRUE,
  "xtumlmc_cleanse_model" => TRUE,
  "xtumlmc_cleanse_inserts" => TRUE,
  "xtumlmc_cleanse_for_BridgePoint" => TRUE,
  "xtuml_integrity" => TRUE );

#
# This condition will succeed only when the user is calling xtumlmc_build
# with the intention of running one of the utility functions listed above.
# If the condition fails, continue on to the xtumlmc_build section.
#
if ( $xtumlmc_utility_routines{ $ARGV[ 0 ] } ) {
  my $func_name = shift( @ARGV );
  &$func_name( @ARGV );
  exit;
}


#=====================================================================
#=====================================================================
#
# xtumlmc_build MAIN:
#
#=====================================================================
#=====================================================================

print localtime() . "\n";       # Record starting time.
print "xtumlmc_build @ARGV\n";  # Record invoked command.

#---------------------------------------------------------------------------
# Get unique serial number for unique file names.
#---------------------------------------------------------------------------
my @tt = localtime();
my $serial = "$tt[5]$tt[4]$tt[6]$tt[2]$tt[1]_$$";

#---------------------------------------------------------------------------
# Parse the command line arguments and assign variables to what is found.
# Get xtUML domain names and SQL files.
# Get marking files, .c files and .h files into arrays indexed by
# the associated xtUML domain.
# Get makefiles and link_sys into their own variables.
#---------------------------------------------------------------------------
my $build_spec = "vc";
my $called_from_eclipse = 0;
my $do_compile = 0;
my $do_gen_xml = 0;
my $do_second_gen_sys = 0;
my $build_directory = $serial;
my $output_src = "../../src";
my $debug_output_dir = "../../Debug/Output";
my $xmiarc = "";
my $mc_type = "";
my @xmls;
my $CONCATENATED_FILE;

#----------------------------------------------------------------------------
# A switch is # identified as a sting that starts with a '-' or a '/' any
# other arguments are considered an option for the preceding switch.
#----------------------------------------------------------------------------
for ( my $i = 0; $i < @ARGV; $i++ ) {
  my $k = $ARGV[$i] if ( $ARGV[$i] =~ s/^-// );
  if ( $k =~ /^(2)$/ ) { $mc = "mc2020"; }
  elsif ( $k =~ /^(3)$/ ) { $mc = "mc"; }
  elsif ( $k =~ /^(b)$/ ) { $i++; $build_spec = $ARGV[$i]; }
  elsif ( $k =~ /^(d)$/ ) { $i++; $build_directory = $ARGV[$i]; }
  elsif ( $k =~ /^(e)$/ ) { $called_from_eclipse=1; }
  elsif ( $k =~ /^(c)$/ ) { $do_compile=1; }
  elsif ( $k =~ /^(g)$/ ) { $do_gen_xml=1; }
  elsif ( $k =~ /^(f)$/ ) {
    $i++; 
    determineBuildFileType( $ARGV[$i] );
  }
  elsif ( $k =~ /^(home)$/ ) { $i++; }
  elsif ( $k =~ /^(i)$/ ) { $xmiarc = "$ENV{'XTUMLMC_HOME'}/$mc/arc/xtuml_xmi2.1_export.arc"; }
  elsif ( $k =~ /^(l2s)$/ ) { $mc_type = " -l2s "; }
  elsif ( $k =~ /^(l2b)$/ ) { $mc_type = " -l2b "; }
  elsif ( $k =~ /^(l3s)$/ ) { $mc_type = " -l3s "; }
  elsif ( $k =~ /^(l3b)$/ ) { $mc_type = " -l3b "; }
  elsif ( $k =~ /^(lSCs)$/ ) { $mc_type = " -lSCs "; }
  elsif ( $k =~ /^(m)$/ ) { $i++; @sqls = ( @sqls, $ARGV[$i] ); }
  elsif ( $k =~ /^(o)$/ ) { $i++; @ooas = ( @ooas, $ARGV[$i] ); }
  elsif ( $k =~ /^(O)$/ ) { $i++; $output_src = $ARGV[$i]; }
  elsif ( $k =~ /^(s)$/ ) { $i++; @sqls = ( @sqls, $ARGV[$i] ); }
  elsif ( $k =~ /^(x)$/ ) { $i++; @xmls = ( @xmls, $ARGV[$i] ); }
  elsif ( $k =~ /^(v)|^(version)$/ ) { print "$file_version\n"; }
  else { die "Unrecognized argument ($k) to xtumlmc_build\n"; }
}
$ENV{'ROX_OUTPUT_SRC_DIR'}=$output_src;

if ( 1 == $called_from_eclipse ) {
  my $DIR = xtumlmc_opendir( "." );
  my @entries = readdir $DIR;
  if ( scalar(@entries) > 0 ) {
    foreach $entry ( @entries ) {
      determineBuildFileType( $entry );
    }
  }
    
}

# Remove duplicates from list of domains.
my @uniq = keys %{{ map { $_ => 1 } @ooas }};
@ooas = @uniq;

#---------------------------------------------------------------------------
# Set up path to the model compiler bin directory.
#---------------------------------------------------------------------------
my $rox_pt_home = $ENV{'XTUMLMC_HOME'};
$ENV{'ROX_MC_ROOT_DIR'} = "$rox_pt_home/$mc" if ( ! exists $ENV{'ROX_MC_ROOT_DIR'} );
$ENV{'ROX_MC_BIN_DIR'} = "$rox_pt_home/$mc/bin" if ( ! exists $ENV{'ROX_MC_BIN_DIR'} );

# Prepend the model compiler bin directory to the beginning of the path.
# Prepend the Cygwin bin directory to the beginning of the path.
# This will give the build visibility to our utilties.
my $current_path = $ENV{'PATH'};
my $mc_bin_dir = $ENV{'ROX_MC_BIN_DIR'};
my $cygwin_path = $ENV{'ROX_CYGWIN_ROOT_DIR'};
if ( $current_path =~ /;/ ) {
  $ENV{'PATH'} = "$mc_bin_dir;$cygwin_path/bin;$current_path";
} else {
  $mc_bin_dir = rox_path( -u, $mc_bin_dir );
  $cygwin_path = rox_path( -u, $cygwin_path );
  $ENV{'PATH'} = "$mc_bin_dir:$cygwin_path/bin:$current_path";
}

#---------------------------------------------------------------------------
# Create system build directory.
#---------------------------------------------------------------------------
if ( "mc" eq $mc ) {
  xtumlmc_init_workspace_3020( $build_directory, "" );
} else {
  usage();
  exit;
}

#---------------------------------------------------------------------------
# If no models supplied, exit without doing much.
#---------------------------------------------------------------------------
if ( 0 == scalar(@sqls) ) {
  # If empty go check for models in the build directory (typically "code_generation")
  my $DIR = xtumlmc_opendir( $build_directory );
  my @entries = readdir $DIR;
  if ( 0 == scalar(@entries) ) {
    die "No models to compile.  Exiting...\n";
  } else {
    foreach $entry ( @entries ) {
      if ( $entry =~ /(\.sql|\.xtuml)/ ) {
        @sqls = ( @sqls, $build_directory . "/" . $entry );
      }
    }
  }
}

#---------------------------------------------------------------------------
# Copy SQL files to the directory where build will find them.
# Clean up the files by removing graphic data and relocatable
# action language elements.
#---------------------------------------------------------------------------
my $tempUUIDfile = "$build_directory/model_temp_uuid_${serial}";
my $modelBeingTranslated = "_system.sql";
my $numSQLs = scalar(@sqls);
if ( 1 != $numSQLs ) {
  die "Expected 1 model file, and there are $numSQLs";
} 

foreach my $sql ( @sqls ) {
  # Copy file across if it exists.
  if ( -f $sql ) {
    # replace UUIDs with 32-bit values
    ReplaceUUIDWithLong( $sql, $tempUUIDfile );

    # Get rid of graphics & proxy entries and non-ASCII characters in the model file.
    xtumlmc_cleanse_model( $tempUUIDfile, ">$build_directory/$modelBeingTranslated", 'true' );

    # Remove the temporary UUID file
    xtumlmc_rm( $tempUUIDfile );

  } else {
    die "SQL file $sqlfile does not seem to exist. Exiting...\n";
  }
}

#---------------------------------------------------------------------------
# Create the directory structure for the application domains.
#---------------------------------------------------------------------------
my $ooa;
chdir $build_directory;
mkpath( "_ch" ) if ( ! -d "_ch" );

#
# Create all the marking files.  They need to exist even if they 
# are empty.
#
xtumlmc_open(">bridge.mark");
xtumlmc_open(">datatype.mark");
xtumlmc_open(">system.mark");
xtumlmc_open(">autosar.mark");
xtumlmc_open(">domain.mark");
xtumlmc_open(">event.mark");
xtumlmc_open(">class.mark");

#---------------------------------------------------------------------------
# Copy in marking files.
#---------------------------------------------------------------------------
foreach $file ( @system_mark ) {
  if ( $file =~ /bridge\.mark/ ) {
    xtumlmc_concat( "../$file", "bridge.mark" );
  } elsif ( $file =~ /datatype\.mark/) {
    xtumlmc_concat( "../$file", "datatype.mark" );
  } elsif ( $file =~ /system\.mark/ ){
    xtumlmc_concat( "../$file", "system.mark");
  } elsif ( $file =~ /autosar\.mark/ ){
    xtumlmc_concat( "../$file", "autosar.mark");
  }
}

#
# Capture the single-file domain-level marking files.
# If these exist, concatentate them in.  These do not need a 
# select statement, because the use the "new-style" marks
# that specify the domain to mark.
#
for ( my $j = 0; $j < @mark; $j++ ) {
  if ( $mark[$j] =~ /domain\.mark/ ) {
    xtumlmc_concat( "../$mark[$j]", "domain.mark" );
    $mark[$j] = "";
  } elsif ( $mark[$j] =~ /event\.mark/ ) {
    xtumlmc_concat( "../$mark[$j]","event.mark");
    $mark[$j] = "";
  } elsif ( $mark[$j] =~ /class\.mark/ ) {
    xtumlmc_concat( "../$mark[$j]","class.mark");
    $mark[$j] = "";
  } elsif ( $mark[$j] =~ /sys_functions\.arc/ ) {
    xtumlmc_copy( "../$mark[$j]","sys_functions.arc");
    $mark[$j] = "";
  } elsif ( $mark[$j] =~ /dom_functions\.arc/ ) {
    xtumlmc_copy( "../$mark[$j]","dom_functions.arc");
    $mark[$j] = "";
  }
}

#
# Check for any marking files left over.  If so, report a warning.
#
for ( my $i = 0; $i < @mark; $i++ ) {
  if ( $mark[$i] ne "" ) {
    print STDERR "\nWARNING:  Marking file $mark[$i] is not recognized.\n";
  }
}

#---------------------------------------------------------------------------
# If we have the XMI Export archetype specified, use it, otherwise if there
# is an arc file in the gen folder, use it and exit.
#---------------------------------------------------------------------------
if ( ( scalar(@arcs) > 0 ) || ( $xmiarc ne "" ) ) {
  my $archcmd;
  foreach $arcfile ( @arcs ) {
    $archcmd .= " -arch ../$arcfile";
  }
  if ( $xmiarc ne "" ) {
    $archcmd = " -arch $xmiarc";
  }
  xtumlmc_gen_erate( "$mc_type -nopersist -d 0 -import $schema -d 0 -import ${modelBeingTranslated} $archcmd" );

  if ( 0 == $called_from_eclipse ) {
    my $root_node = rox_path( "-m", "." );
    $root_node =~ s/(\r|\n)//g;
    if ( ! -e "$root_node/_ch" ) {
      xtumlmc_mkdir( "$root_node/_ch" );
    }
    $output_src = "$root_node/_ch";
  }

  foreach my $ooa ( @ooas ) {
    if ( -f "${ooa}/schema/sql/${ooa}_xmi_2_1\.xml" ) {
      xtumlmc_copy( "${ooa}/schema/sql/${ooa}_xmi_2_1\.xml", $output_src );
      print "\nYour XML output has been placed in $output_src/${ooa}_xmi_2_1\.xml\.\n";
    }
  }

  exit;
}

#---------------------------------------------------------------------------
# Handle the situation where the user has new-style archetype folder
#---------------------------------------------------------------------------
# create arc dir under code_generation
my $build_arcdir = "$ENV{'ROX_APP_ROOT_DIR'}/arc";
xtumlmc_mkdir($build_arcdir);

# copy arc/* to code_gen/arc
my $DIR = xtumlmc_opendir( $arcdir ); my @entries = readdir $DIR;
foreach $entry ( @entries ) {
  if ( -f "$arcdir/$entry" ) {
    xtumlmc_copy( "$arcdir/$entry", "$build_arcdir/$entry" );
  }
}
    
# If they have a specialized folder use that, otherwise look at the 
# mc_type flag
my $specialized_arcdir = "$arcdir/specialized";
if ( -d "$specialized_arcdir" ) {
  # no variable mod needed, copy arc/specialized/* to code_gen/arc
} else {
  if ( $mc_type eq " -l2s " ) { $specialized_arcdir = "$arcdir/sysc" }
  elsif ( $mc_type eq " -l2b " ) { $specialized_arcdir = "$arcdir/sysc" }
  elsif ( $mc_type eq " -l3s " ) { $specialized_arcdir = "$arcdir/c" }
  elsif ( $mc_type eq " -l3b " ) { $specialized_arcdir = "$arcdir/c" }
  elsif ( $mc_type eq " -lSCs " ) { $specialized_arcdir = "$arcdir/sysc" }
  else { $specialized_arcdir = "$arcdir/c" }
}
$DIR = xtumlmc_opendir( $specialized_arcdir ); @entries = readdir $DIR;
foreach $entry ( @entries ) {
  if ( -f "$specialized_arcdir/$entry" ) {
    xtumlmc_copy( "$specialized_arcdir/$entry", "$build_arcdir/$entry" );
  }
}
    
# use new arc dir
$ENV{'ROX_MC_ARC_DIR'} = "$build_arcdir";
$arcdir = $ENV{'ROX_MC_ARC_DIR'};

#---------------------------------------------------------------------------
# Generate the system node and then compile.
#---------------------------------------------------------------------------
# Check for compiled model-based model compiler executable.
# If it exists, use it.  Otherwise, use archetypes.
$mccmd = "$ENV{'ROX_MC_BIN_DIR'}/mcmc";
if ( ((-f $mccmd) || (-f "$mccmd.exe")) && ( $mc_type =~ /l3/ ) ) {
  # Get the marks from the marking files to be parsed by mcmc.
  # grep '^ *\.invoke ' *.mark > m.txt
  my $outFile = xtumlmc_open( ">" . "m.txt" );
  my $DIR = xtumlmc_opendir( "." ); my @entries = readdir $DIR;
  my @filtered_entries = grep{/\.mark/i} @entries;
  foreach my $i ( @filtered_entries ) {
    my $inFile = xtumlmc_open( "<" . "$i" );
    while ( <$inFile> ) { if ( /^ *\.invoke / ) { print $outFile "$_"; } }
  }
  close $outFile;
  # If we are compiling the model compiler itself, change the system name
  # and substitute &quot; symbols.
  if ( -f "escher.sql" ) {
    # sed s/escher/sys/ _system.sql > a.xtuml
    my $inFile = xtumlmc_open( "<" . "$modelBeingTranslated" ); my $outFile = xtumlmc_open( ">" . "a.xtuml" );
    while ( <$inFile> ) { s/escher/sys/; print $outFile "$_"; }
    # Run compiled model compiler.
    system( "$mccmd > _system.pre" );
    # sed "s/&quot;/\\\\\"/g" _system.pre > _system.sql
    my $inFile = xtumlmc_open( "<" . "_system.pre" ); my $outFile = xtumlmc_open( ">" . "$modelBeingTranslated" );
    while ( <$inFile> ) { s/&quot;/\\\\\"/g; print $outFile "$_"; }
  } elsif ( -f "escher.sql" ) {
    # sed s/escher/sys/ _system.sql > a.xtuml
    my $inFile = xtumlmc_open( "<" . "$modelBeingTranslated" ); my $outFile = xtumlmc_open( ">" . "a.xtuml" );
    while ( <$inFile> ) { s/escher/sys/; print $outFile "$_"; }
    # Run compiled model compiler.
    system( "$mccmd > _system.pre" );
    # sed "s/&quot;/\\\\\"/g" _system.pre > _system.sql
    my $inFile = xtumlmc_open( "<" . "_system.pre" ); my $outFile = xtumlmc_open( ">" . "$modelBeingTranslated" );
    while ( <$inFile> ) { s/&quot;/\\\\\"/g; print $outFile "$_"; }
  } else {
    xtumlmc_move( "$modelBeingTranslated", "a.xtuml" );
    # Run compiled model compiler.
    system( "$mccmd > $modelBeingTranslated 2> mcconsole.txt" );
    my $inFile = xtumlmc_open( "<" . "mcconsole.txt" );
    while ( <$inFile> ) { print; }
    close $inFile
  }
}
xtumlmc_gen_erate( "$mc_type -nopersist -d 0 -import $schema -d 0 -import ${modelBeingTranslated} -arch \"$arcdir/sys.arc\"" );

#---------------------------------------------------------------------------
# Copy the C files into the correct locations.
# Copy the H files into the correct locations.
# Copy in any Makefiles.
# Copy in the link_sys file.
#---------------------------------------------------------------------------
foreach $f (@c_files) {
  if ( -f "_ch/$f" ) {
    xtumlmc_move( "_ch/$f", "_ch/$f.orig" );
  }
  xtumlmc_copy( "../$f", "_ch" );
}
foreach $f (@h_files) {
  if ( -f "_ch/$f" ) {
    xtumlmc_move( "_ch/$f", "_ch/$f.orig" );
  }
  xtumlmc_copy( "../$f", "_ch" );
}
foreach $f (@make_files) {
  xtumlmc_copy( "../$f", "." );
}
foreach $f (@link_sys) {
  xtumlmc_copy( "../$f", "bin/" );
}

#---------------------------------------------------------------------------
# Gather the source all together.
#---------------------------------------------------------------------------
xtumlmc_sde_init( "." );
if ( -d $output_src ) {
  my $vistadir = "vista_tlm";
  my $DIR = xtumlmc_opendir( "_ch" ); my @entries = readdir $DIR;
  my @tcl_entries = grep{/\.(tcl)$/i} @entries;
  if ( @tcl_entries ) {
    if ( ! -e "$output_src/$vistadir" ) {
      xtumlmc_mkdir("$output_src/$vistadir");
    }
    foreach my $g ( @tcl_entries ) {
      xtumlmc_copy_different( "_ch/$g", "$output_src/$vistadir/$g" );
    }
  }
  my @ch_entries = grep{/\.(c|cc|cpp|h|hh|hpp|xml)$/i} @entries;
  foreach my $f ( @ch_entries ) {
    if ( $f =~ m/(pv_template|sysc_main_template)/i ) {
      xtumlmc_copy_different( "_ch/$f", "$output_src/$vistadir/$f" );
    } else {
      xtumlmc_copy_different( "_ch/$f", "$output_src/$f" );
    }
  }
}

if ( 1 == $do_compile ) {
  if ( "mc" eq $mc ) {
    system( "make all_no_gen" );
  }
}

print "Code generation complete.\n";
print localtime() . "\n";

#---------------------------------------------------------------------------
# Clean up, clean up, everybody everywhere!
#---------------------------------------------------------------------------
unlink "____file.txt" if ( -f "____file.txt" );

