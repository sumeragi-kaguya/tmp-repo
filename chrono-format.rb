#!/usr/bin/env ruby
# frozen_string_literal: true

# chrono-manager: codegeass.ru chronology manager.
# Copyright (c) 2019 Sumeragi Kaguya <nyalice _at_ technologist.com>
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.

require 'cgi/util'
require 'json'
require 'net/http'
require 'time'

require_relative 'data'

INPUT_FILE = 'tmp.txt'
ARC_DIGITS = 2

MONTHS = {
  1 => 'января',
  2 => 'февраля',
  3 => 'марта',
  4 => 'апреля',
  5 => 'мая',
  6 => 'июня',
  7 => 'июля',
  8 => 'августа',
  9 => 'сентября',
  10 => 'октября',
  11 => 'ноября',
  12 => 'декабря'
}.freeze

MONTHS_BACK = MONTHS.invert.freeze

ARCS = {
  0 => nil,
  1 => DateTime.new(2017, 7, 15),
  2 => DateTime.new(2017, 9, 1),
  3 => DateTime.new(2017, 10, 1),
  4 => DateTime.new(2017, 10, 16),
  5 => DateTime.new(2017, 11, 1),
  6 => DateTime.new(2017, 12, 1),
  7 => DateTime.new(2018, 1, 1)
}.freeze

def tz_shift(datetime, tz)
  tz && datetime ? datetime - Rational(tz, 24) : datetime
end

def pick_arc(date)
  ARCS.reverse_each do |key, value|
    return key if value && date >= value
  end

  0
end

class ChronoEntry
  attr_reader :timeless, :name, :id, :start, :end, :chara, :tz, :arc

  def self.from_string(string)
    init_params = {}

    string.each_line do |line|
      if line.start_with? 'Название:'
        init_params[:name] = line
                             .delete_prefix('Название:')
                             .strip
                             .split(nil, 2)
                             .last
      elsif line.start_with? 'Id темы:'
        init_params[:id] = line.delete_prefix('Id темы:').strip.to_i
      elsif line.start_with? 'Начало:'
        init_params[:start] = DateTime.strptime(
          line.delete_prefix('Начало:').strip,
          '%d.%m.%Y %H:%M'
        )
      elsif line.start_with? 'Дата:'
        init_params[:start] = DateTime.strptime(
          line.delete_prefix('Дата:').strip,
          '%d.%m.%Y'
        )
      elsif line.start_with? 'Конец:'
        init_params[:end_] = DateTime.strptime(
          line.delete_prefix('Конец:').strip,
          '%d.%m.%Y %H:%M'
        )
      elsif line.start_with? 'Персонажи:'
        chara_string = line[/Персонажи: \[?(\d+(?:, \d+)*)?\]?/, 1]
        init_params[:chara] = if chara_string
                                chara_string.split(', ').map(&:to_i)
                              else
                                []
                              end
      elsif line.start_with? 'Часовой пояс:'
        tz_candidates = line
                        .gsub(/\[(\d+), ".*?"\]/, '\1')
                        .scan(/\d+/)
                        .map(&:to_i)

        raise ArgumentError, 'Ambiguous timezone' if
          tz_candidates.length > 1
        raise ArgumentError, 'No timezone on timezone line' if
          tz_candidates.empty?

        init_params[:tz] = tz_candidates.first
      end
    end

    init_params[:timeless] = !init_params.key?(:end_)

    init_params[:start] = tz_shift(init_params[:start], init_params[:tz])
    init_params[:end_] = tz_shift(init_params[:end_], init_params[:tz])

    begin
      new(init_params)
    rescue ArgumentError
      nil
    end
  end

  def initialize(timeless: false,
                 name:,
                 id:,
                 start:,
                 end_: nil,
                 chara:,
                 tz:)
    @timeless = timeless
    @name = name
    @id = id
    @start = start
    @end = end_
    @chara = chara
    @tz = tz

    @arc = pick_arc(@start)
  end

  def html
    unless @timeless
      <<~HTML
        <p id="#{@id}"></p>
        <script type="text/javascript">
        setepisode(#{@id},#{@start.day},"#{MONTHS[@start.month]}",#{@start.hour},#{@start.minute},#{@end.hour},#{@end.minute},#{@tz},#{JSON.dump(@name)},0,#{@chara.join(',')},1);
        </script>
      HTML
    else
      char_list = @chara.map do |char_chrono_id|
        %(<a href="http://codegeass.ru/pages/id#{'%02d' % char_chrono_id}">) +
          %(#{CGI.escapeHTML CHARS[char_chrono_id]}</a>)
      end.join(', ')

      <<~HTML
        <div class="chep">
        <div class="chtime1">#{@start.day} #{MONTHS[@start.month]} #{@start.year} года</div>
        <div class="chepname"><a href="http://codegeass.ru/viewtopic.php?id=#{@id}">#{CGI.escapeHTML(@name)}</a></div>
        <div class="chcast">#{char_list}</div>
        <div class="chstat">Завершен</div>
        </div>
      HTML
    end
  end

  def to_json
    <<~JSON.chomp
      {"id": #{@id},
       "start": "#{@start}",
       "end": "#{@end}",
       "tz": #{@tz},
       "turn": #{@arc},
       "name": "#{CGI.escapeHTML(@name)}",
       "mode": 0,
       "chara": #{@chara},
       "done": true
      }
    JSON
  end
end

def read_input_file
  entries = []
  entry = String.new

  File.foreach(INPUT_FILE) do |line|
    line.chomp!

    if line == '------'
      entry = ChronoEntry.from_string(entry)
      entries << entry if entry
      entry = String.new
      next
    end

    entry << "\n" << line unless line.empty?
  end

  entries
end

def read_chrono_pages
  entries = []
  Net::HTTP.start('codegeass.ru') do |http|
    ARCS.each_key do |arc|
      response = http.get("http://codegeass.ru/pages/chronology#{arc}")
      body = response.body.encode(Encoding::UTF_8, Encoding::Windows_1251)

      body.each_line do |line|
        year = arc < 7 ? 2017 : 2018

        if (match = line.match(%r{setepisode\(
          (?<id>\d+),
          (?<day>\d+),
          '(?<month>.*?)',
          (?<start_hour>\d+),
          (?<start_minute>\d+),
          (?<end_hour>\d+),
          (?<end_minute>\d+),
          (?<tz>\d+),
          '(?<name>.*?)',
          (?<mode>\d+),
          (?<chara>\d+(?:,\d+)*),
          (?<done>\d+)
        \);}x))
          name = match['name'].gsub(/((?:^|[^\\])(?:\\\\)*)"/, '\1\"')
          name = JSON.parse(%("#{name}"))
          month = match['month'].gsub(/((?:^|[^\\])(?:\\\\)*)"/, '\1\"')
          month = JSON.parse(%("#{month}"))
          start = DateTime.new(year,
                               MONTHS_BACK[month],
                               match['day'].to_i,
                               match['start_hour'].to_i,
                               match['start_minute'].to_i)
          end_ = DateTime.new(year,
                              MONTHS_BACK[month],
                              match['day'].to_i,
                              match['end_hour'].to_i,
                              match['end_minute'].to_i)

          entries << ChronoEntry.new(
            timeless: false,
            name: name,
            id: match['id'].to_i,
            chara: match['chara'].split(',').map(&:to_i),
            tz: match['tz'].to_i
            start: start,
            end_: end_,
          )
        elsif (match = line.match(%r{setepisodenotime\(
          (?<id>\d+),
          '(?<start_day>\d+)\ (?<start_month>.*?)',
          '(?<end_day>\d+)\ (?<end_month>.*?)',
          '(?<name>.*?)',
          (?<mode>\d+),
          (?<chara>\d+(?:,\d+)*),
          (?<done>\d+)
        \);}x))
          name = match['name'].gsub(/((?:^|[^\\])(?:\\\\)*)"/, '\1\"')
          name = JSON.parse(%("#{name}"))
          start_month = match['start_month'].gsub(/((?:^|[^\\])(?:\\\\)*)"/, '\1\"')
          start_month = JSON.parse(%("#{start_month}"))
          end_month = match['end_month'].gsub(/((?:^|[^\\])(?:\\\\)*)"/, '\1\"')
          end_month = JSON.parse(%("#{end_month}"))

          # FORGOT ABOUT TZ SHIFT

          entries << ChronoEntry.new(
            timeless: false,
            name: name,
            id: match['id'].to_i,
            start: DateTime.new(year,
                                MONTHS_BACK[start_month],
                                match['start_day'].to_i),
            end_: DateTime.new(year,
                               MONTHS_BACK[end_month],
                               match['end_day'].to_i),
            chara: match['chara'].split(',').map(&:to_i),
            tz: 0
          )
        elsif (match = line.match(%r{
          <div\ class="chep">
            <div\ class="chtime0">
              \((?<day>\d+)\ (?<month>.*?)\)<br>
              \ (?<start_hour>\d+):(?<start_minute>\d+)\ -
              \ (?<end_hour>\d+):(?<end_minute>\d+)
            </div>
            <div\ class="chtime">
              \((?<tzs_day>\d+)\ (?<tzs_month>.*?)\)<br>
              \ (?<tzs_start_hour>\d+):(?<tzs_start_minute>\d+)\ -
              \ .*?
            </div>
            <div\ class="chepname">
              <a\ href="http://codegeass\.ru/viewtopic\.php\?id=(?<id>\d+)">
                (?<name>.*?)
              </a>
            </div>
            <div\ class="chcast">
              (?<chara_string>
                (?:<a\ href="http://codegeass.ru/pages/id\d+">.*?</a>,?)+
              )
            </div>
            <div\ class="chstat">(?<done_string>.*?)</div>
          </div>
        }x))
          day = match['day'].to_i
          month = MONTHS_BACK[match['month']]
          start_hour = match['start_hour'].to_i
          start_minute = match['start_minute'].to_i
          end_hour = match['end_hour'].to_i
          end_minute = match['end_minute'].to_i
          tzs_day = match['tzs_day'].to_i
          tzs_month = MONTHS_BACK[match['tzs_month']]
          tzs_start_hour = match['tzs_start_hour'].to_i
          tzs_start_minute = match['tzs_start_minute'].to_i
          id = match['id'].to_i
          name = match['name']
          chara = match['chara_string']
                  .split(', ')
                  .map do |href|
                    href[%r{<a\ href="http://codegeass.ru/pages/id(\d+)">}, 1]
                      .to_i
                  end
          done = match['done_string'] == 'Завершен'
          start = DateTime.new(year,
                               month,
                               day,
                               start_hour,
                               start_minute)
          end_ = DateTime.new(year,
                              month,
                              day,
                              end_hour,
                              end_minute)
          tzs_start = DateTime.new(year,
                                   tzs_month,
                                   tzs_day,
                                   tzs_start_hour,
                                   tzs_start_minute)
          tz = ((tzs_start - start) * 24).to_i

          entries << ChronoEntry.new(
            timeless: false,
            name: name,
            id: id,
            start: start,
            end_: end_,
            chara: chara,
            tz: tz
          )
        end
      end
    end
  end
end

def main
  read_chrono_pages

  # episode_array = read_input_file.sort_by do |item|
  #   arc_sort = item.arc.zero? ? 10 ** ARC_DIGITS - 1 : item.arc
  #   arc_sort = "%0#{ARC_DIGITS}d" % arc_sort
  #   "#{arc_sort} #{item.start} #{item.name}"
  # end

  # episode_array = episode_array
  #                 .each
  #                 .map(&:to_json)
  #                 .join(",\n")
  #                 .each_line
  #                 .map {|line| '  ' + line}
  #                 .join
  # puts %([\n#{episode_array}\n])
end

main if $PROGRAM_NAME == __FILE__
