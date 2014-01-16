class LogWatcher < Scout::Plugin

  # In this file, /var/log/simpana/Log_Files/clBackupParent.log,
  # match this:
  # ::parent() - Successful completion of the Backup
  # report a backup event, then this, from the next line:
  # STATISTICS: 9419 files, 13101903467334 bytes
  #
  # If you match this:
  # 25711 8e88e700 04/02 08:34:38 218438 ::parent() - Backup Failed
  # generate an alert.

OPTIONS = <<-EOS
  log_path:
    default: "/var/log/simpana/Log_Files/clBackupParent.log"
    name: Log path (clBackupParent.log)
    notes: Full path to the the log file
  send_error_if_no_log:
    attributes: advanced
    default: 1
    notes: 1=yes
  EOS

  def init
    @log_file_path = option("log_path").to_s.strip
    if @log_file_path.empty?
      return error( "Please provide a path to the log file." )
    end

    unless File.exists?(@log_file_path)
      error("Could not find the log file", "The log file could not be found at: #{@log_file_path}. Please ensure the full path is correct.") if option("send_error_if_no_log") == "1"
      return
    end

    nil
  end

  def build_report
    return if init()

    failures = String.new
    last_log_size = memory(:commvault_log_size) || 0
    current_length = `wc -c #{@log_file_path}`.split(' ')[0].to_i
    # don't run it the first time
    if (last_log_size > 0 )
      read_length = current_length - last_log_size
      # Check to see if this file was rotated. This occurs when the +current_length+ is less than
      # the +last_run+. Don't return a count if this occured.
      if read_length >= 0
        # finds new content from +last_bytes+ to the end of the file, then just extracts from the recorded
        # +read_length+. This ignores new lines that are added after finding the +current_length+. Those lines
        # will be read on the next run.
        total_files = 0
        total_bytes = 0
        match = `tail -c +#{last_log_size+1} #{@log_file_path} | head -c #{read_length} | grep -A 1 '::parent() - Successful completion of the Backup'`
        match.split("\n").each do |line|
          files = line.match('(\d+) files')
          unless files.nil?
            total_files = total_files + files[1].to_i
          end
          bytes = line.match('(\d+) bytes')
          unless bytes.nil?
            total_bytes = total_bytes + bytes[1].to_i
          end
        end
        failures = `tail -c +#{last_log_size+1} #{@log_file_path} | head -c #{read_length} | grep '::parent() - Backup Failed'`
      else
        total_files = nil
        total_bytes = nil
      end
    end
    report(:files => total_files) if total_files
    report(:bytes => total_bytes) if total_bytes
    alert("Commvault Backup Failed") unless failures.empty?
    remember(:commvault_log_size, current_length)
  end
end
