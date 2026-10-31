# frozen_string_literal: true

require 'json'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)
AUTOPLAY_DIR = File.join(ROOT, 'tmp', 'ai_autoplay')
FIXTURE_DIR = File.join(ROOT, 'public', 'fixtures')

LOCAL_URL = 'http://localhost:9292'

game_id = ARGV.first

unless game_id
  warn 'Usage:'
  warn '  bundle exec ruby scripts/ai_autoplay/view_game.rb GAME'
  warn
  warn 'Example:'
  warn '  bundle exec ruby scripts/ai_autoplay/view_game.rb 1830'
  exit 1
end

pattern = File.join(
  AUTOPLAY_DIR,
  "#{game_id}*",
  'current.json'
)

matches = Dir.glob(pattern).select do |filename|
  File.file?(filename)
end

if matches.empty?
  warn "No autoplay checkpoint found for: #{game_id}"
  warn "Looked for: #{pattern}"
  exit 1
end

checkpoint_file = matches.max_by do |filename|
  File.mtime(filename)
end

checkpoint = JSON.parse(
  File.read(checkpoint_file)
)

safe_id = game_id
  .downcase
  .gsub(/[^a-z0-9_-]+/, '_')
  .gsub(/\A_+|_+\z/, '')

fixture_name = "autoplay_#{safe_id}"

fixture_dir = File.join(
  FIXTURE_DIR,
  fixture_name
)

fixture_file = File.join(
  fixture_dir,
  'current.json'
)

FileUtils.mkdir_p(fixture_dir)

players = checkpoint.fetch('players')
actions = checkpoint.fetch('actions')
settings = checkpoint.fetch('settings', {})

viewer_data = {
  'id' => fixture_name,
  'description' => "AI autoplay #{checkpoint['title']}",
  'user' => {
    'id' => 0,
    'name' => 'You',
  },
  'players' => players,
  'min_players' => players.size,
  'max_players' => players.size,
  'title' => checkpoint.fetch('title'),
  'settings' => settings,
  'user_settings' => {},
  'status' => 'finished',
  'turn' => 1,
  'round' => 'Operating',
  'acting' => [],
  'result' => {},
  'actions' => actions,
  'loaded' => true,
  'created_at' => Time.now.to_i,
  'updated_at' => Time.now.to_i,
  'finished_at' => Time.now.to_i,
}

File.write(
  fixture_file,
  JSON.generate(viewer_data)
)

url = "#{LOCAL_URL}/fixture/#{fixture_name}/current"

puts
puts 'Autoplay checkpoint:'
puts "  #{checkpoint_file}"
puts
puts 'Browser fixture:'
puts "  #{fixture_file}"
puts
puts 'Opening dashboard:'
puts "  #{url}"
puts

case RUBY_PLATFORM
when /darwin/
  system('open', url)
when /linux/
  system('xdg-open', url)
else
  puts 'Open the URL above in your browser.'
end
