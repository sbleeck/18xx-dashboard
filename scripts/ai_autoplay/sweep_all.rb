# frozen_string_literal: true

require 'csv'
require 'fileutils'
require 'json'
require 'open3'
require 'optparse'
require 'rbconfig'
require 'timeout'

ROOT = File.expand_path('../..', __dir__)
AUTOPLAY_SCRIPT = File.join(ROOT, 'scripts', 'ai_autoplay', 'autoplay.rb')
RESULT_ROOT = File.join(ROOT, 'tmp', 'ai_autoplay', 'catalogue_sweep')
GAME_ROOT = File.join(RESULT_ROOT, 'games')
LOG_ROOT = File.join(RESULT_ROOT, 'logs')
CSV_FILE = File.join(RESULT_ROOT, 'results.csv')
HTML_FILE = File.join(RESULT_ROOT, 'index.html')
FIXTURE_ROOT = File.join(ROOT, 'public', 'fixtures', 'ai_catalogue')

LOCAL_URL = 'http://localhost:9292'

CSV_HEADERS = %w[
  title
  status
  exit_code
  actions
  elapsed_seconds
  moves_per_second
  round
  step
  acting_entity
  exception_class
  exception_message
  checkpoint
  failure_report
  stdout_log
  stderr_log
  fixture
  inspection_url
].freeze

options = {
  players: 4,
  seed: 12_345,
  max_moves: 2_000,
  timeout_seconds: 600,
  rerun: false,
  open_tabs: false,
}

parser = OptionParser.new do |opts|
  opts.banner = <<~TEXT
    Run every registered 18xx title through the AI autoplay harness.

    Usage:
      bundle exec ruby scripts/ai_autoplay/sweep_all.rb [options]
  TEXT

  opts.on(
    '--players NUMBER',
    Integer,
    'Number of players requested for every game (default: 4)'
  ) do |value|
    options[:players] = value
  end

  opts.on(
    '--seed NUMBER',
    Integer,
    'Deterministic seed used for every game (default: 12345)'
  ) do |value|
    options[:seed] = value
  end

  opts.on(
    '--max-moves NUMBER',
    Integer,
    'Maximum actions per game (default: 2000)'
  ) do |value|
    options[:max_moves] = value
  end

  opts.on(
    '--timeout-seconds NUMBER',
    Integer,
    'Hard subprocess timeout per game (default: 600)'
  ) do |value|
    options[:timeout_seconds] = value
  end

  opts.on(
    '--rerun',
    'Rerun titles already recorded in results.csv'
  ) do
    options[:rerun] = true
  end

  opts.on(
    '--open-tabs',
    'Open every available inspection fixture after the sweep'
  ) do
    options[:open_tabs] = true
  end

  opts.on('-h', '--help', 'Show help') do
    puts opts
    exit 0
  end
end

parser.parse!(ARGV)

def safe_name(title)
  title
    .downcase
    .gsub(/[^a-z0-9_-]+/, '_')
    .gsub(/\A_+|_+\z/, '')
end

def read_json(filename)
  return nil unless filename && File.file?(filename)

  JSON.parse(File.read(filename))
rescue JSON::ParserError, Errno::ENOENT
  nil
end

def last_action_count(checkpoint)
  Array(checkpoint&.fetch('actions', [])).size
end

def failure_details(failure)
  return {} unless failure.is_a?(Hash)

  exception = failure['exception']

  {
    'round' =>
      failure['round'] ||
      failure.dig('game', 'round'),
    'step' =>
      failure['step'] ||
      failure.dig('game', 'step'),
    'acting_entity' =>
      failure['acting_entity'] ||
      failure.dig('game', 'acting_entity'),
    'exception_class' =>
      if exception.is_a?(Hash)
        exception['class']
      else
        failure['exception_class']
      end,
    'exception_message' =>
      if exception.is_a?(Hash)
        exception['message']
      else
        failure['exception_message'] || exception
      end,
  }
end

def parse_output(stdout)
  result = {}

  if (match = stdout.match(/Finished:\s*(true|false)/))
    result['finished'] = match[1] == 'true'
  end

  if (match = stdout.match(/Total actions:\s*(\d+)/))
    result['actions'] = match[1].to_i
  end

  if (match = stdout.match(/Elapsed time:\s*([\d.]+)\s+seconds/))
    result['reported_elapsed'] = match[1].to_f
  end

  if (match = stdout.match(%r{Speed:\s*([\d.]+)\s+moves/second}))
    result['reported_speed'] = match[1].to_f
  end

  result
end

def create_fixture(title:, checkpoint_file:)
  checkpoint = read_json(checkpoint_file)
  return [nil, nil] unless checkpoint

  id = safe_name(title)
  fixture_dir = File.join(FIXTURE_ROOT, id)
  fixture_file = File.join(fixture_dir, 'current.json')

  FileUtils.mkdir_p(fixture_dir)

  players = Array(checkpoint['players'])
  actions = Array(checkpoint['actions'])
  now = Time.now.to_i

  game_data = {
    'id' => "ai_catalogue_#{id}",
    'description' => "AI catalogue sweep: #{title}",
    'user' => {
      'id' => 0,
      'name' => 'You',
    },
    'players' => players,
    'min_players' => players.size,
    'max_players' => players.size,
    'title' => checkpoint.fetch('title', title),
    'settings' => checkpoint.fetch('settings', {}),
    'user_settings' => {},
    'status' => 'finished',
    'turn' => 1,
    'round' => '',
    'acting' => [],
    'result' => {},
    'actions' => actions,
    'loaded' => true,
    'created_at' => now,
    'updated_at' => now,
    'finished_at' => now,
  }

  File.write(
    fixture_file,
    JSON.generate(game_data)
  )

  relative_fixture = fixture_file.delete_prefix("#{ROOT}/")
  url = "#{LOCAL_URL}/fixture/ai_catalogue/#{id}/current"

  [relative_fixture, url]
end

def html_escape(value)
  value
    .to_s
    .gsub('&', '&amp;')
    .gsub('<', '&lt;')
    .gsub('>', '&gt;')
    .gsub('"', '&quot;')
    .gsub("'", '&#39;')
end

def read_rows
  return [] unless File.file?(CSV_FILE)

  CSV.read(
    CSV_FILE,
    headers: true
  ).map(&:to_h)
end

def write_html(rows)
  status_counts = rows.group_by { |row| row['status'] }
                      .transform_values(&:size)

  inspectable_urls = rows
    .map { |row| row['inspection_url'] }
    .compact
    .reject(&:empty?)

  body_rows = rows.map do |row|
    status = row['status'].to_s

    link =
      if row['inspection_url'].to_s.empty?
        ''
      else
        %(<a href="#{html_escape(row['inspection_url'])}" target="_blank">Inspect</a>)
      end

    failure =
      [
        row['exception_class'],
        row['exception_message'],
      ].compact.reject(&:empty?).join(': ')

    <<~HTML
      <tr class="status-#{html_escape(status)}">
        <td>#{html_escape(row['title'])}</td>
        <td>#{html_escape(status)}</td>
        <td>#{html_escape(row['actions'])}</td>
        <td>#{html_escape(row['elapsed_seconds'])}</td>
        <td>#{html_escape(row['moves_per_second'])}</td>
        <td>#{html_escape(row['round'])}</td>
        <td>#{html_escape(row['step'])}</td>
        <td>#{html_escape(row['acting_entity'])}</td>
        <td class="failure">#{html_escape(failure)}</td>
        <td>#{link}</td>
      </tr>
    HTML
  end.join

  url_json = JSON.generate(inspectable_urls)

  html = <<~HTML
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>18xx AI Catalogue Sweep</title>
      <style>
        body {
          font-family: system-ui, -apple-system, sans-serif;
          margin: 24px;
          color: #1a1a1a;
        }

        h1 {
          margin-bottom: 8px;
        }

        .summary {
          margin: 12px 0 20px;
          padding: 12px;
          background: #f2f4f7;
          border-radius: 8px;
        }

        button {
          padding: 8px 14px;
          margin-right: 8px;
          cursor: pointer;
        }

        table {
          width: 100%;
          border-collapse: collapse;
          margin-top: 18px;
          font-size: 13px;
        }

        th, td {
          border: 1px solid #d8d8d8;
          padding: 6px 8px;
          text-align: left;
          vertical-align: top;
        }

        th {
          background: #eceff3;
          cursor: pointer;
          position: sticky;
          top: 0;
        }

        tr.status-success {
          background: #eaf7ea;
        }

        tr.status-failed {
          background: #fff0f0;
        }

        tr.status-timeout {
          background: #fff5df;
        }

        tr.status-incomplete {
          background: #f3edff;
        }

        tr.status-unsupported_player_count {
          background: #eeeeee;
        }

        .failure {
          max-width: 420px;
          overflow-wrap: anywhere;
        }
      </style>
    </head>
    <body>
      <h1>18xx AI Catalogue Sweep</h1>

      <div class="summary">
        <strong>Total tested:</strong> #{rows.size}<br>
        <strong>Success:</strong> #{status_counts.fetch('success', 0)}<br>
        <strong>Failed:</strong> #{status_counts.fetch('failed', 0)}<br>
        <strong>Timeout:</strong> #{status_counts.fetch('timeout', 0)}<br>
        <strong>Incomplete:</strong> #{status_counts.fetch('incomplete', 0)}<br>
        <strong>Unsupported:</strong>
        #{status_counts.fetch('unsupported_player_count', 0)}
      </div>

      <button onclick="openAll()">Open all inspection tabs</button>
      <button onclick="location.reload()">Reload results</button>

      <table id="results">
        <thead>
          <tr>
            <th onclick="sortTable(0)">Title</th>
            <th onclick="sortTable(1)">Status</th>
            <th onclick="sortTable(2)">Actions</th>
            <th onclick="sortTable(3)">Seconds</th>
            <th onclick="sortTable(4)">Moves/s</th>
            <th onclick="sortTable(5)">Round</th>
            <th onclick="sortTable(6)">Step</th>
            <th onclick="sortTable(7)">Entity</th>
            <th onclick="sortTable(8)">Failure</th>
            <th>Position</th>
          </tr>
        </thead>
        <tbody>
          #{body_rows}
        </tbody>
      </table>

      <script>
        const inspectionUrls = #{url_json};

        function openAll() {
          inspectionUrls.forEach((url) => {
            window.open(url, '_blank');
          });
        }

        function sortTable(column) {
          const table = document.getElementById('results');
          const body = table.tBodies[0];
          const rows = Array.from(body.rows);
          const direction =
            table.dataset.sortColumn == column &&
            table.dataset.sortDirection == 'asc'
              ? 'desc'
              : 'asc';

          rows.sort((a, b) => {
            const av = a.cells[column].innerText.trim();
            const bv = b.cells[column].innerText.trim();

            const an = Number(av);
            const bn = Number(bv);

            let comparison;

            if (!Number.isNaN(an) && !Number.isNaN(bn)) {
              comparison = an - bn;
            } else {
              comparison = av.localeCompare(bv);
            }

            return direction == 'asc'
              ? comparison
              : -comparison;
          });

          rows.forEach((row) => body.appendChild(row));

          table.dataset.sortColumn = column;
          table.dataset.sortDirection = direction;
        }
      </script>
    </body>
    </html>
  HTML

  File.write(HTML_FILE, html)
end

def open_url(url)
  case RUBY_PLATFORM
  when /darwin/
    system('open', url)
  when /linux/
    system('xdg-open', url)
  else
    warn "Open manually: #{url}"
  end
end

FileUtils.mkdir_p(RESULT_ROOT)
FileUtils.mkdir_p(GAME_ROOT)
FileUtils.mkdir_p(LOG_ROOT)
FileUtils.mkdir_p(FIXTURE_ROOT)

require_relative '../../lib/engine'

titles = Engine::GAME_METAS
  .map(&:title)
  .uniq
  .sort

existing_rows = read_rows
completed_titles = existing_rows
  .map { |row| row['title'] }
  .to_h { |title| [title, true] }

unless File.file?(CSV_FILE)
  CSV.open(CSV_FILE, 'wb') do |csv|
    csv << CSV_HEADERS
  end
end

puts
puts "Registered titles: #{titles.size}"
puts "Players requested: #{options[:players]}"
puts "Seed: #{options[:seed]}"
puts "Maximum moves: #{options[:max_moves]}"
puts "Per-game timeout: #{options[:timeout_seconds]} seconds"
puts "Results: #{CSV_FILE}"
puts

titles.each_with_index do |title, index|
  if !options[:rerun] && completed_titles[title]
    puts format(
      '[%3d/%3d] SKIP %s',
      index + 1,
      titles.size,
      title
    )
    next
  end

  safe = safe_name(title)
  output_dir = File.join(GAME_ROOT, safe)
  stdout_file = File.join(LOG_ROOT, "#{safe}.stdout.log")
  stderr_file = File.join(LOG_ROOT, "#{safe}.stderr.log")
  checkpoint_file = File.join(output_dir, 'current.json')
  failure_file = File.join(output_dir, 'failure.json')

  FileUtils.rm_rf(output_dir)
  FileUtils.mkdir_p(output_dir)

  puts format(
    '[%3d/%3d] RUN  %s',
    index + 1,
    titles.size,
    title
  )

  command = [
    RbConfig.ruby,
    AUTOPLAY_SCRIPT,
    '--new',
    title,
    '--players',
    options[:players].to_s,
    '--seed',
    options[:seed].to_s,
    '--max-moves',
    options[:max_moves].to_s,
    '--output',
    output_dir,
  ]

  stdout = +''
  stderr = +''
  exit_code = nil
  timed_out = false

  started_at =
    Process.clock_gettime(Process::CLOCK_MONOTONIC)

  begin
    Timeout.timeout(options[:timeout_seconds]) do
      stdout, stderr, status = Open3.capture3(
        *command,
        chdir: ROOT,
      )

      exit_code = status.exitstatus
    end
  rescue Timeout::Error
    timed_out = true
    stderr << "\nSWEEP TIMEOUT after #{options[:timeout_seconds]} seconds\n"
  rescue StandardError => e
    stderr << "\nSWEEP PROCESS ERROR: #{e.class}: #{e.message}\n"
  end

  elapsed =
    Process.clock_gettime(Process::CLOCK_MONOTONIC) -
    started_at

  File.write(stdout_file, stdout)
  File.write(stderr_file, stderr)

  checkpoint = read_json(checkpoint_file)
  failure = read_json(failure_file)
  parsed = parse_output(stdout)
  details = failure_details(failure)

  action_count =
    parsed['actions'] ||
    last_action_count(checkpoint)

  speed =
    if action_count.positive? && elapsed.positive?
      action_count / elapsed
    else
      0.0
    end

  status =
    if timed_out
      'timeout'
    elsif parsed['finished']
      'success'
    elsif checkpoint.nil? &&
          (
            stderr.match?(/player/i) &&
            stderr.match?(/min|max|support|number/i)
          )
      'unsupported_player_count'
    elsif checkpoint && action_count >= options[:max_moves]
      'incomplete'
    else
      'failed'
    end

  fixture_path, inspection_url =
    create_fixture(
      title: title,
      checkpoint_file: checkpoint_file,
    )

  row = {
    'title' => title,
    'status' => status,
    'exit_code' => exit_code,
    'actions' => action_count,
    'elapsed_seconds' => format('%.3f', elapsed),
    'moves_per_second' => format('%.3f', speed),
    'round' => details['round'],
    'step' => details['step'],
    'acting_entity' => details['acting_entity'],
    'exception_class' => details['exception_class'],
    'exception_message' => details['exception_message'],
    'checkpoint' =>
      (checkpoint_file.delete_prefix("#{ROOT}/") if File.file?(checkpoint_file)),
    'failure_report' =>
      (failure_file.delete_prefix("#{ROOT}/") if File.file?(failure_file)),
    'stdout_log' => stdout_file.delete_prefix("#{ROOT}/"),
    'stderr_log' => stderr_file.delete_prefix("#{ROOT}/"),
    'fixture' => fixture_path,
    'inspection_url' => inspection_url,
  }

  CSV.open(CSV_FILE, 'ab') do |csv|
    csv << CSV_HEADERS.map { |header| row[header] }
  end

  current_rows = read_rows
  write_html(current_rows)

  puts format(
    '          %-25s actions=%-5d seconds=%7.2f speed=%6.2f',
    status,
    action_count,
    elapsed,
    speed
  )
end

rows = read_rows
write_html(rows)

puts
puts 'Sweep finished.'
puts "CSV: #{CSV_FILE}"
puts "HTML: #{HTML_FILE}"
puts "Inspectable games: #{rows.count { |row| !row['inspection_url'].to_s.empty? }}"
puts

open_url("file://#{HTML_FILE}")

if options[:open_tabs]
  rows.each do |row|
    url = row['inspection_url']
    next if url.to_s.empty?

    open_url(url)
  end
end
