class CustomerDiskUsageReportReader < Scout::Plugin
  needs 'json'

  # TODO: fix this comment
  # In the data directory, /data:
  # find all folders except "." and ".."
  #
  # If a matching database is found, then gather the
  # size of the mongo database, the size of the contents
  # of the folder, and the number of batches in the Output
  # folder, and report to Scout.
  #
  # Do this once every ten runs.  Most of the time, do nothing.
  #
  # If you can't connect to Mongo, then give up.

  OPTIONS = <<-EOS
  usage_report_path:
    default: /tmp/.customer_disk_usage_report.json
    name: Customer Disk Usage Report
    notes: JSON file created by an async job
  data_dir:
    default: /data
    name: Data Directory
    notes: Path to the base data directory
  mongo_server:
    default: 127.0.0.1
    name: MongoDB IP address
  database_prefix:
    default: ascent_production_
    name: Database name prefix
  customers_to_report:
    name: Customers to include in report
  EOS

  def init
    @usage_report_path = option(:usage_report_path).to_s.strip
    if @usage_report_path.empty?
      return error( "Please provide a path to the usage report path." )
    end

    @data_dir = option(:data_dir).to_s.strip
    if @data_dir.empty?
      return error( "Please provide a path to the data directory." )
    end

    @mongo_server = option(:mongo_server).to_s.strip
    if @mongo_server.empty?
      return error( "Please provide an IP address for MongoDB." )
    end

    @database_prefix = option(:database_prefix).to_s.strip
    if @database_prefix.empty?
      return error( "Please provide a database prefix name for customer databases." )
    end

    @customers_to_report = Array.new
    if option(:customers_to_report)
      @customers_to_report = option(:customers_to_report).split(',').collect{ |c| c.strip }
    end

    unless Dir.exists?(@data_dir)
      return error("Could not find the raw data folder", "The directory could not be found at: #{@data_dir}. Please ensure the full path is correct.") if option("send_error_if_no_log") == "1"
    end

    nil
  end

  def build_report
    return if init()

    create_async_job

    unless File.exists?(@usage_report_path)
      alert("#{@usage_report_path} does not exist.")
      run_async_job
    end

    if File.mtime(@usage_report_path) < Time.now - (3 * 60 * 60)
      run_async_job
    end

    if File.mtime(@usage_report_path) < Time.now - (12 * 60 * 60)
      alert("#{@usage_report_path} is too old.  Check that the async job has run.")
    else

      customers = Hash.new

      File.open(@usage_report_path, "r") do |fh|
        customers = ::JSON.parse(fh.read)
      end

      customers.each_key do |c|
        if (@customers_to_report.include?(c) or @customers_to_report.empty?)
          report("#{c}_fs_usage".to_sym => customers[c]['fs_usage'])
          report("#{c}_db_usage".to_sym => customers[c]['db_usage'])
          report("#{c}_total".to_sym => customers[c]['fs_usage'].to_i + customers[c]['db_usage'].to_i)
          report("#{c}_batch_count".to_sym => customers[c]['batch_count'])
        end
       end
    end
  end

  def create_async_job()
    File.open("/tmp/.customer_disk_usage_report_creator.rb", "w") do |fh|
      fh.puts <<BOLLOCKS
#!/usr/bin/env ruby

require 'rubygems'
require 'mongo'
require 'json'

include Mongo
include JSON

class CustomerDiskUsageReportCreator

  def initialize(option)
    @data_dir = option[:data_dir] || "#{@data_dir}"
    @mongo_server = option[:mongo_server] || "#{@mongo_server}"
    @database_prefix = option[:database_prefix] || "#{@database_prefix}"
    @usage_report_path = option[:usage_report_path] || "#{@usage_report_path}"
  end
BOLLOCKS

      fh.puts <<'BOLLOCKS'
  def preflight_check
    if @data_dir.empty?
      return( "Please provide a path to the data directory." )
    end

    if @mongo_server.empty?
      return( "Please provide an IP address for MongoDB." )
    end

    if @database_prefix.empty?
      return( "Please provide a database prefix name for customer databases." )
    end

    if @usage_report_path.empty?
      return( "Please provide a report path." )
    end

    unless Dir.exists?(@data_dir)
      return( "Could not find the data folder" )
    end

    nil
  end

  def build_report
    return if preflight_check()

    customers = Hash.new

    @mongo_client = ::Mongo::MongoClient.new(@mongo_server, :slave_ok => true)
    dbs = @mongo_client.database_info

    customer_folders = Dir.entries(@data_dir).reject { |d| d =~ /^\./ }
    customer_folders.each do |f|
      next unless dbs.has_key?("#{@database_prefix}#{f}")

      customers[f] = {
        :fs_usage => fs_used(f),
        :db_usage => db_used(f),
        :batch_count => batch_count(f)
      }
    end

    File.open(@usage_report_path, "w") do |fh|
      fh.puts JSON.pretty_generate(customers)
    end
  end

  def fs_used(customer)
    du = `du -b -s #{File.join(@data_dir,customer)}`
    # ffs what's wrong with grep on a String object?
    used = du.match(/^\d+/).to_s.to_i
    convert_to_megabytes(used)
  end

  def db_used(customer)
    used = @mongo_client.db("#{@database_prefix}#{customer}").stats['dataSize']
    convert_to_megabytes(used)
  end

  def batch_count(customer)
    if Dir.exists?(File.join(@data_dir,customer,"Output"))
      count = Dir.entries(File.join(@data_dir,customer,"Output")).reject { |i| i =~ /^\./ }.count
      count
    else
      0
    end
  end

  def convert_to_megabytes(value)
    value / 1024 / 1024 # English units?
  end
end
BOLLOCKS

      fh.puts <<BOLLOCKS
report = CustomerDiskUsageReportCreator.new( { :mongo_server => "#{@mongo_server}", :data_dir => "#{@data_dir}", :database_prefix => "#{@database_prefix}", :usage_report_path => "#{@usage_report_path}" } )
report.build_report
BOLLOCKS
    end

    File.chmod(0755, "/tmp/.customer_disk_usage_report_creator.rb")
  end

  def run_async_job
    unless system('ps -C ruby -o args | grep report_creator')
      spawn("/tmp/.customer_disk_usage_report_creator.rb")
    end
  end
end
