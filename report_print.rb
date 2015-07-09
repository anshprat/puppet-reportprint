#!/usr/bin/ruby

require 'puppet'
require 'pp'
require 'optparse'

class ::Numeric
  def bytes_to_human
    # Prevent nonsense values being returned for fractions
    if self >= 1
      units = ['B', 'KB', 'MB' ,'GB' ,'TB']
      e = (Math.log(self)/Math.log(1024)).floor
      # Cap at TB
      e = 4 if e > 4
      s = "%.2f " % (to_f / 1024**e)
      s.sub(/\.?0*$/, units[e])
    else
      "0 B"
    end
  end
end

def load_report(path)
  YAML.load_file(path)
end

def report_resources(report)
  report.resource_statuses
end

def resource_by_eval_time(report)
  report_resources(report).reject{|r_name, r| r.evaluation_time.nil? }.sort_by{|r_name, r| r.evaluation_time rescue 0}
end

def resources_of_type(report, type)
  report_resources(report).select{|r_name, r| r.resource_type == type}
end

def color(code, msg, reset=false)
  colors = {:red => "[31m", :green => "[32m", :yellow => "[33m", :cyan => "[36m", :bold => "[1m", :reset => "[0m", :underline => "[4m"}

  return "%s%s%s%s" % [colors.fetch(code, ""), msg, colors[:reset], reset ? colors.fetch(reset, "") : ""] if @options[:color]

  msg
end

def print_report_summary(report)
  puts color(:bold, "Report for %s in environment %s at %s" % [color(:underline, report.host, :bold), color(:underline, report.environment, :bold), color(:underline, report.time, :bold)])
  puts
  puts "             Report File: %s" % @options[:report]
  puts "             Report Kind: %s" % report.kind
  puts "          Puppet Version: %s" % report.puppet_version
  puts "           Report Format: %s" % report.report_format
  puts "   Configuration Version: %s" % report.configuration_version
  puts "                    UUID: %s" % report.transaction_uuid rescue nil
  puts "               Log Lines: %s %s" % [report.logs.size, @options[:logs] ? "" : "(show with --log)"]

  puts
end

def print_report_metrics(report, file='')
  print_slow_files = false
  puts color(:bold, "Report Metrics:")
  puts file

  padding = report.metrics.map{|i, m| m.values}.flatten(1).map{|i, m, v| m.size}.sort[-1] + 6

  report.metrics.sort_by{|i, m| m.label}.each do |i, metric|
    puts "   %s:" % metric.label

    metric.values.sort_by{|i, m, v| v}.reverse.each do |i, m, v|
      puts "%#{padding}s: %s" % [m, v]
      metric_label    = @options[:metric_label]
      metric_sublabel = @options[:metric_sublabel]
      metric_value    = @options[:metric_value]
      if metric_label  == metric.label  and m  == metric_sublabel and v.to_int > metric_value
        # Print slow reports only for total time > metric_value
        print_slow_files = true
      end
    end

    puts
  end

  return print_slow_files
end

def print_summary_by_type(report)
  summary = {}

  report_resources(report).each do |resource|
    if resource[0] =~ /^(.+?)\[/
      name = $1

      summary[name] ||= 0
      summary[name] += 1
    else
      STDERR.puts "ERROR: Cannot parse type %s" % resource[0]
    end
  end

  puts color(:bold, "Resources by resource type:")
  puts

  summary.sort_by{|k, v| v}.reverse.each do |type, count|
    puts "   %4d %s" % [count, type]
  end

  puts
end

def print_slow_resources(report, number=20, rep_file='',debug=false , resource_type=[])
  if (debug)
    puts "Processing #{rep_file}"
  end
  if report.report_format < 4
    puts color(:red, "   Cannot print slow resources for report versions %d" % report.report_format)
    puts
    return
  end

  resources = resource_by_eval_time(report)

  number = resources.size if resources.size < number
  priv_res = []
  if @options[:report_type] == "single"
    puts color(:bold, "Slowest %d resources by evaluation time:" % number)
    puts

    resources[(0-number)..-1].reverse.each do |r_name, r|
      puts "   %7.2f %s" % [r.evaluation_time, r_name]
    end
  end
  if @options[:report_type] == "combi"
    resources[(0-number)..-1].reverse.each do |r_name, r|
      if (resource_type.length >0)
          resource_type.each do |res_name|
            if (r_name.include? res_name)
              priv_res <<  [r.evaluation_time, r_name, rep_file]
            end
          end
      else
        priv_res <<  [r.evaluation_time, r_name, rep_file]
      end
        
    end
    priv_res.sort!{|x,y| y<=>x}
  return priv_res
  end
end

def print_logs(report)
  puts color(:bold, "%d Log lines:" % report.logs.size)
  puts

  report.logs.each do |log|
    puts "   %s" % log.to_report
  end

  puts
end

def print_files(report, number=20)
  resources = resources_of_type(report, "File")

  files = {}

  resources.each do |r_name, r|
    if r_name =~ /^File\[(.+)\]$/
      file = $1

      if File.exist?(file) && File.readable?(file) && File.file?(file) && !File.symlink?(file)
        files[file] = File.size?(file) || 0
      end
    end
  end

  number = files.size if files.size < number

  puts color(:bold, "%d largest managed files" % number) + " (only those with full path as resource name that are readable)"
  puts

  files.sort_by{|f, s| s}[(0-number)..-1].reverse.each do |f_name, size|
    puts "   %9s %s" % [size.bytes_to_human, f_name]
  end

  puts
end

def initialize_puppet
  require 'puppet/util/run_mode'
  Puppet.settings.preferred_run_mode = :agent
  Puppet.settings.initialize_global_settings([])
  Puppet.settings.initialize_app_defaults(Puppet::Settings.app_defaults_for_run_mode(Puppet.run_mode))
end

initialize_puppet

opt = OptionParser.new

@options = {:logs                 => false,
            :count                => 20,
            :report               => Puppet[:lastrunreport],
            :color                => STDOUT.tty?,
            :metric_label         => "Time",
            :metric_sublabel      => "Total",
            :metric_value         => 20,
            :report_type          => "single",
            :unique               => false,
            :debug                => false,
            :slow_filter          => ['Package'],
            :file_print_summary   => false,
            :print_files          => false,
           }

opt.on("--logs", "Show logs") do |val|
  @options[:logs] = val
end

opt.on("--count [RESOURCES]", Integer, "Number of resources to show evaluation times for") do |val|
  @options[:count] = val
end

opt.on("--report [REPORT]", "Path to the Puppet last run report") do |val|
  #abort("Could not find report %s" % val) unless File.readable?(val)
  @options[:report] = val
end

opt.on("--[no-]color", "Colorize the report") do |val|
  @options[:color] = val
end

opt.on("--metric_label [#{@options[:metric_label]}]", "First label to look for") do |val|
  @options[:metric_label] = val
end

opt.on("--metric_sublabel [#{@options[:metric_sublabel]}]", "Sub label to look for ") do |val|
  @options[:metric_sublabel] = val
end

opt.on("--metric_value [#{@options[:metric_value]}]", Float,  "Metric value high pass filter ") do |val|
  @options[:metric_value] = val
end

opt.on("--report_type [#{@options[:report_type]}]", "Type of report (single|combi)") do |val|
  @options[:report_type] = val
end

opt.on("--slow_filter #{@options[:slow_filter]}", Array, "Resource types filtered in slow report, CSV") do |val|
  @options[:slow_filter] = val
end

opt.on("--debug [#{@options[:debug]}]","Enable debug") do |val|
  @options[:debug] = val
end

opt.on("--unique [#{@options[:unique]}]","Print only unique resource types in slow report, only in combi mode") do |val|
  @options[:unique] = val
end

opt.on("--file_print_summary [#{@options[:file_print_summary]}]","Print report summary in combi mode") do |val|
  @options[:file_print_summary] = val
end

opt.on("--print_files [#{@options[:print_files]}]","Print managed files list") do |val|
  @options[:print_files] = val
end

opt.parse!
if @options[:report_type]  == "single"
  report = load_report(@options[:report])

  print_report_summary(report)
  print_slow_files = print_report_metrics(report)
  print_summary_by_type(report) if print_slow_files
  print_slow_resources(report, @options[:count]) if print_slow_files
  print_files(report, @options[:count]) if @options[:print_files]
  print_logs(report) if @options[:logs]
end

# take the reports and process them to get the stuff I care about out
def parse_report(report_obj)
  report = {}
  report['start_time']            = report_obj.time
  report['status']                = report_obj.status
  report['configuration_version'] = report_obj.configuration_version
  report['metrics']               = {}
  report['resources']             = {}

  report_obj.metrics['time'].values.each do |x|
    if x[0] == 'total'
      report['total_time'] = x[2]
    end
  end
  if report['status'] == 'failed'
    report['resources']['failed'] = {}
    report_obj.resource_statuses.each do |k,v| 
      if v.failed
        v.events.each do |x|
          report['resources']['failed'][k] ||= []
          report['resources']['failed'][k].push(x.message)
        end
      end
      # we may have to do this in Puppet 4, but in 3, we can
      # rely on failed to exist on the resource_status
      #v.events do |x|
      #  puts x.status
      #  if x.status = 'failure'
      #    report['resources']['failed'][k] ||= []
      #    report['resources']['failed'][k].push(x.message)
      #  end
      #end 
    end
  end
  report
end

def organize_reports(report_objs)
  reports = {}
  report_objs.each do |x|
    reports[x['configuration_version']] ||= {}
    reports[x['configuration_version']][x['start_time']] = x
  end
  reports
end

def print_single_report(reports, key)
  times = reports[key].keys.sort
  times.each do |t|
    report = reports[key][t]
    puts "  Started at #{t}, took #{report['total_time']}, result #{report['status']}"
    if report['status'] == 'failed'
      report['resources']['failed'].each do |k,v|
        puts "    #{k}: #{v}"
      end
    end
  end
end

def print_organized_reports(reports)
  special_keys  = ['settings', 'packages', 'bootstrap']

  special_keys.each do |k|
    puts "For run type: #{k}"
    if reports[k]
      if reports[k].size != 1
        puts "Expected 1 run, found #{reports[k].size}"
      end
      print_single_report(reports, k)
    else
      puts "  Did not find expected report: #{k}"
    end
  end
  # None should not exist?
  if reports['None']
    puts "Unexpected run type: None"
    print_single_report(reports, 'None')
  end

  versions = reports.keys - special_keys - ['None']

  versions.each do |x|
    puts "Found #{reports[x].size} report(s) for version #{x}"
    print_single_report(reports, x)
  end
end

if @options[:report_type] == 'dans_type'
  rep_dir = '/var/lib/puppet/reports/'
  reports = []
  for file in Dir.glob("#{rep_dir}/*/*")
    report = parse_report(load_report(file))
    reports.push(report) 
  end
  print_organized_reports(organize_reports(reports))
elsif @options[:report_type] == "combi" or File.directory?(@options[:report])
  local_res = []
  reports_l_base = "#{Puppet[:reportdir]}/"
  if @options[:report].include? "RDIR/"
    rep_dir = "#{reports_l_base}#{@options[:report]}"
    rep_dir.sub!('RDIR/','')
  else
    rep_dir = @options[:report]
  end
#  puts rep_dir
  for file in Dir.glob("#{rep_dir}")
    report = load_report(file)
    print_report_summary(report) if @options[:file_print_summary]
    for el in print_slow_resources(report, @options[:count], file, @options[:debug], @options[:slow_filter])
      local_res.push(el)
#      puts "   %7.10f %s %s" % [el[0],el[1],el[2]]
     end
    print_report_metrics(report, file)
  end
  local_res.sort!{|x,y| y<=>x}
  local_res.uniq!{ |el| el.fetch(1) } if @options[:unique] == true
  local_res = local_res.take(@options[:count])
  puts color(:bold, "Slowest %d resources by evaluation time:" % @options[:count])
  for el in local_res
    puts "   %7.3f %s %s" % [el[0],el[1],el[2]]
  end
end
