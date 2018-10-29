[CmdletBinding()]
Param(
	[Switch] $NoSkip,
	[Switch] $NoMemoryWarn
)
$WorkingDir = split-path -parent $MyInvocation.MyCommand.Definition;
. (Join-Path $WorkingDir 'functions.ps1')
#Always read the source file first incase of a new variable.
. (Join-Path $WorkingDir "versions_src.ps1")
#user overrides
if (Test-Path ./versions.ps1 -PathType Leaf){
	. (Join-Path $WorkingDir "versions.ps1")
}
Set-StrictMode -version latest;
$ErrorActionPreference = "Stop";
$PSSenderInfo = Get-Variable -name "PSSenderInfo" -ErrorAction SilentlyContinue;
if ($PSSenderInfo){
	Write-Host -Foreground Yellow "Warning when running this build command in a remote powershell session you will not see any of the output generated by commands run.  This is due to a limitation in remote powershell.  You can work around this by running the build.ps1 using remote desktop instead.  In general it is only helpful to see the output if there is an error."
}
$global:PERF_FILE = Join-Path $WorkingDir "perf.log";
if ((Get-MpPreference).DisableRealtimeMonitoring -eq $false){ #as admin you can disable with: Set-MpPreference -DisableRealtimeMonitoring $true
	Write-Host Warning, windows defender is enabled it will slow things down. -Foreground Red 
}
if (! $NoMemoryWarn){
	$page_files = Get-CimInstance Win32_PageFileSetting;
	$os = Get-Ciminstance Win32_OperatingSystem;
	$min_gigs = 27;
	$warning = "linking may take around $min_gigs during linking";
	if ($VAR_DUAL_BUILD -eq "1"){
		$warning="dual build mode is enabled and may use 50+ GB if both releases link at once.";
		$min_gigs = 50;
	}
	if (($os.FreePhysicalMemory/1mb + $os.FreeSpaceInPagingFiles/1mb) -lt $min_gigs) { #if the memory isn't yet avail with the page files and they have a set size lets try to compute it that way
		$total_memory_gb = $os.FreePhysicalMemory/1mb;
		foreach ($file in $page_files){
			$total_memory_gb += $file.MaximumSize/1kb; #is zero if system managed, then we really don't know how big it could be.
		}
		if ($total_memory_gb -lt $min_gigs){
			if (! (confirm("Warning $warning.  Your machine may not have enough memory, make sure your page files are working and can grow to allow it. (Disable this warning with -$NoMemoryWarn flag). Do you want to proceed?"))){
				exit 1;
			}

		}
	}
}


echo *.zip | out .dockerignore
TimerNow("Starting");
RunProc -proc "docker" -opts "pull $VAR_BASE_DOCKER_FILE";
TimerNow("Pull base file");
RunProc -proc "docker" -opts "build $VAR_HYPERV_MEMORY_ADD --build-arg BASE_DOCKER_FILE=`"$VAR_BASE_DOCKER_FILE`" -f Dockerfile_vs -t vs ."
TimerNow("VSBuild");
if ($VAR_CEF_USE_BINARY_PATH -and $VAR_CEF_USE_BINARY_PATH -ne ""){
	$docker_file_name="Dockerfile_cef_create_from_binaries";

	$good_hash = Get-FileHash $docker_file_name;
	$new_path = Join-Path $VAR_CEF_USE_BINARY_PATH $docker_file_name;
	if ( (Test-Path $new_path -PathType Leaf) -eq $false -or (Get-FileHash $new_path).Hash -ne $good_hash.Hash){
		Copy $docker_file_name $VAR_CEF_USE_BINARY_PATH;
	}
	$loc = Get-Location;
	Set-Location -Path $VAR_CEF_USE_BINARY_PATH;
	RunProc -proc "docker" -opts "build $VAR_HYPERV_MEMORY_ADD -f $docker_file_name -t cef ."
	Set-Location $loc;
} else {
	RunProc -proc "docker" -opts "build $VAR_HYPERV_MEMORY_ADD --build-arg DUAL_BUILD=`"$VAR_DUAL_BUILD`" --build-arg GN_DEFINES=`"$VAR_GN_DEFINES`" --build-arg GYP_DEFINES=`"$VAR_GYP_DEFINES`" --build-arg CHROME_BRANCH=`"$VAR_CHROME_BRANCH`" -f Dockerfile_cef -t cef ."
}

TimerNow("CEF Build");
if (! $VAR_CEF_BUILD_ONLY){
	RunProc -proc "docker" -opts "build $VAR_HYPERV_MEMORY_ADD --build-arg BINARY_EXT=`"$VAR_CEF_BINARY_EXT`" -f Dockerfile_cef_binary -t cef_binary ."
	TimerNow("CEF Binary compile");
	RunProc -proc "docker" -opts "build $VAR_HYPERV_MEMORY_ADD --build-arg CEFSHARP_BRANCH=`"$VAR_CEFSHARP_BRANCH`" --build-arg CEFSHARP_VERSION=`"$VAR_CEFSHARP_VERSION`" --build-arg CEF_VERSION_STR=`"$VAR_CEF_VERSION_STR`" --build-arg CHROME_BRANCH=`"$VAR_CHROME_BRANCH`" -f Dockerfile_cefsharp -t cefsharp ."
	TimerNow("CEFSharp compile");
	docker rm cefsharp;
	Start-Sleep -s 3; #sometimes we are too fast, file in use error
	RunProc -proc "docker" -opts "run --name cefsharp cefsharp cmd /C echo CopyVer"
	RunProc -proc "docker" -opts "cp cefsharp:/packages_cefsharp.zip ."
	TimerNow("CEFSharp copy files locally");
}else{
	docker rm cef;
	Start-Sleep -s 3; #sometimes we are too fast, file in use error
	RunProc -proc "docker" -opts "run --name cef powershell Compress-Archive -Path C:/code/binaries/*.zip -CompressionLevel Fastest -DestinationPath /packages_cef"
	RunProc -proc "docker" -opts "cp cef:/packages_cef.zip ."
	
	TimerNow("CEF copy files locally");
}