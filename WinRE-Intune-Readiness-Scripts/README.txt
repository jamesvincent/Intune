WinRE and Intune Remote Wipe readiness
=====================================

This package assesses Windows Recovery Environment (WinRE) and related
conditions before a planned Intune wipe. The remediation script can enable
or register an existing recovery image. None of the scripts initiates a
wipe or validates a reset end to end.

Files and exit codes
--------------------
WinRE-WipeReadiness-Standalone.ps1
  Run from an elevated Windows PowerShell 5.1 session to see the full
  assessment table and log path. From the package folder, run:

    .\WinRE-WipeReadiness-Standalone.ps1

  Exit 0 = READY, 1 = READY WITH WARNING, 2 = NOT READY.
  Use -StrictKB5079471 to make an absent or uninspectable KB a failure
  on applicable releases. Use -LogDirectory to change the log location.

Detect-WinRERemoteWipeReadiness.ps1
  Upload as the Intune Remediations detection script. Exit 0 means there
  are no WARN or FAIL results. Exit 1 means at least one WARN or FAIL
  was found and triggers the paired remediation. INFO results, including
  the low WinRE free-space advisory, do not trigger remediation.

Remediate-WinRERemoteWipeReadiness.ps1
  Upload as the paired remediation script. It checks whether REAgentC
  reports WinRE enabled with a registered location. If needed, it tries
  reagentc /enable. If that does not resolve the issue, it checks the
  default image at %SystemRoot%\System32\Recovery\Winre.wim with DISM,
  then attempts to register that image and enable WinRE.

  Exit 0 means WinRE was already enabled and registered or that the script
  confirmed that state after remediation. Exit 1 means the script could
  not confirm that state or encountered an error. Exit 0 does not clear
  other detection findings. Disk resizing, Safe OS updates, component
  store repair and manual BCD repair are outside the remediation scope.

What the assessment checks
--------------------------
- WinRE is enabled, its registered location maps to a partition, and
  Winre.wim is present and readable by DISM.
- WinRE is on a separate partition from Windows. The same partition
  fails. On the same disk, WinRE before Windows passes with a layout
  advisory and WinRE after Windows passes as the preferred order.
  WinRE on a different disk is reported as INFO.
- Recovery partition capacity below 500 MB and an unexpected GPT type,
  when reported, are separate WARN results.
- WinRE partition free space below 250 MB is INFO for WinRE servicing.
  At or above 250 MB passes. There is no 52 MB failure threshold.
- Windows volume free space fails below 10 GB and otherwise warns below
  20 GB or 10 percent free. These are script guardrails.
- The active Windows loader's BCD recovery entry must resolve. If
  REAgentC supplies a BCD identifier, a mismatch warns. The comparison
  ignores braces around the GUIDs.
- DISM checks the Windows component store. The assessment also checks
  for a pending reboot and whether the RemoteWipe CSP can be queried.

KB5079471 check
---------------
On Windows 11 24H2 and 25H2, the assessment mounts WinRE read-only and
searches the package inventory for the literal KB5079471 identifier.
Detection treats an absent or uninspectable result as FAIL. Standalone
treats it as WARN by default and FAIL with -StrictKB5079471. Other
releases, including 26H1, show INFO (Not applicable). A superseding
Safe OS update can make the literal check fail. Verify the installed
servicing baseline before treating a missing match as conclusive.

Intune settings and output
--------------------------
- Run this script using the logged-on credentials: No (runs as SYSTEM)
- Run script in 64-bit PowerShell: Yes

Pre-Remediation Detection Output shows one summary line. READY means
no WARN or FAIL results. NONCOMPLIANT lists the names and counts of
warnings and failures. The free-space advisory is appended when present.

Example when 71 MB free on WinRE is the only advisory:

WinRE READY: all required checks passed, including KB5079471 for applicable releases. Servicing advisory: WinRE partition has 71 MB free of 1152 MB (target 250 MB free).

Logs
----
Default folder: %ProgramData%\WinREReadiness\Logs
- Standalone and detection: WinRE_Readiness_<computer>_<timestamp>.log
- Remediation: Remediation.log

Use the device logs for the individual check results and the REAgentC
output. Detection and standalone can temporarily add a partition access
path or mount the WIM read-only for inspection, then attempt cleanup.
