class WindowsLogWatcher < Scout::Plugin
  needs 'win32/file'

  OPTIONS = <<-EOS
  log_path:
    name: Log path
    notes: Full path to the log file
  term:
    default: "[Ee]rror"
    name: Search Term
    notes: Returns the number of matches for this term.  Use Regex formatting.
  send_error_if_no_log:
    attributes: advanced
    default: 1
    notes: 1=yes
  EOS

  def init
    @log_file_path = option("log_path").to_s.strip
    if @log_file_path.empty?
      return error("Please provide a path to the log file.")
    end

    unless File.exists?(@log_file_path)
      if option("send_error_if_no_log").to_s == "1"
        return error("Log file does not exist.", "The log file could not be found at #{@log_file_path}.")
      end
    end

    @term = option("term").to_s.strip
    if @term.empty?
      return error("The term cannot be empty.")
    end

    nil
  end

  def build_report
    return if init()

    last_length = memory(:last_bytes) || 0
    current_length = File.size(@log_file_path)
    matches = 0
    elapsed_seconds = 0

    if last_length > 0
      read_length = current_length - last_length
      # Check to see if this file was rotated.  This occurs when the +current_length+ is less than the
      # +last_length+.  Don't return a count if this occurs.
      if read_length > 0

      # The shell commands that are available to tail a file by X number of bytes in UNIX don't exist
      # in Windows, or if they do they're not worth using because they're DOS-based and DOS is icky.  Use
      # the IO class instead.  Hopefully IO.read doesn't become a huge memory hog.
        IO.read(@log_file_path, current_length, last_length).split("\r\n").each do |line|
          if line.match(@term)
            matches += 1
          end
        end
      else
        matches = 0
      end
    end

    counter(:log_matches, matches, :per => :minute, :round => true)
    remember(:last_bytes, current_length)
  end
end
