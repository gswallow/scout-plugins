require 'ffi'
require 'ffi/tools/const_generator'

module LinuxCLib
  extend FFI::Library
  ffi_lib 'c'

  @@cg = FFI::ConstGenerator.new(nil, :required => true) do |gen|
    gen.include('unistd.h')
    gen.const(:_SC_CLK_TCK)
  end

  attach_function :sysconf, [:int], :long

  def self.hz
    self.sysconf(@@cg["_SC_CLK_TCK"].to_i)
  end
end

class LongRunningProcess < Scout::Plugin
  needs 'sys/proctable'

  # Given a regex and a time, check to see how long processes that match
  # the regex have been running and alert if the process has been running
  # longer than time.

  OPTIONS = <<-EOS
  process:
    name: Process
    notes: Regex to search for
  time:
    default: 60
    name: Time
    notes: Max time for process to exist (in minutes)
  kill:
    default: false
    name: Kill running process?
  EOS

  def init
    @process = option(:process).to_s.strip
    if @process.empty?
      return error( "Please provide the name of a process to find" )
    end

    @time = option(:time).to_s.strip
    unless @time =~ /\d+/
      return error( "Please provide a maximum allowable time for the process to exist" )
    end

    @kill = option(:kill).to_s.strip
    case @kill
      when "true", "false"
        nil
      else
        return error( "Please specify whether to kill long running processes (true/false)" )
    end

    nil
  end

  def uptime
    File.open("/proc/uptime","r").readline.chop.split(/\s+/).first.to_i
  end

  def process_run_time(proc)
    uptime - (proc.starttime / LinuxCLib.hz)
  end

  def kill(proc)
    Process.kill('INT', proc.pid)
    sleep 2
    Process.kill('TERM', proc.pid) if Process.kill(0, proc.pid)
    sleep 2
    alert("Could not kill process #{proc.pid}") if Process.kill(0, proc.pid)
  end

  def build_report
    return if init()

    @long_running_procs = 0

    procs = Sys::ProcTable.ps.select { |p| p['cmdline'] =~ /#{@process}/ }
    procs.each do |proc|
      if process_run_time(proc) > @time.to_i * 60
        @long_running_procs += 1
        alert("#{proc.cmdline} has been running for #{process_run_time(proc) / 60} minutes")
        kill(proc) if @kill == "true"
      end
    end
  end

  report(:long_running_processes => @long_running_procs)
end
