@echo off
REM Behavioural simulation without a Vivado project (Windows).
REM Run from a "Vivado <version> Tcl Shell" or any cmd window where settings64.bat was called.
REM   cd <package>\sim
REM   run_xsim.bat          (GUI with waveforms)
REM   run_xsim.bat batch    (console only)
setlocal
cd /d %~dp0
copy /Y ..\rtl\sincos_qw.mem . >nul
call xvlog -sv ..\rtl\sincos_qw_rom.sv ..\rtl\noise_src.sv ..\rtl\chirp_core.sv ..\rtl\chirp_axil_regs.sv ..\rtl\chirp_gen_top.sv ..\rtl\chirp_gen_wrapper.v tb_chirp_gen.sv || goto :err
call xelab -debug typical tb_chirp_gen -s tb_chirp_sim || goto :err
if /I "%1"=="batch" (
    call xsim tb_chirp_sim -R
) else (
    call xsim tb_chirp_sim -gui -tclbatch xsim_wave.tcl
)
goto :eof
:err
echo Compilation failed.
exit /b 1
