require 'net/http/persistent'
require 'nokogiri'
require 'thread'
require 'monitor'
require 'fileutils'
Thread.abort_on_exception = true

DEST = ARGV[0]

class ThreadExecutor
  class Promise
    def initialize job
      @job   = job
      @value = nil
      @latch = Latch.new
    end

    def run(*args)
      @value = @job.call(*args)
      @latch.release
    end

    def value
      @latch.await
      @value
    end
  end

  class Latch
    def initialize count = 1
      @count = count
      @lock  = Monitor.new
      @cv    = @lock.new_cond
    end

    def release
      @lock.synchronize do
        @count -= 1 if @count > 0
        @cv.broadcast if @count == 0
      end
    end

    def await
      @lock.synchronize { @cv.wait_while { @count > 0 } }
    end
  end

  def initialize size
    @queue = Queue.new
    @size = size
    @pool = size.times.map { |i|
      Thread.new {
        conn = Net::HTTP::Persistent.new "dn_#{i}"

        while job = @queue.pop
          job.run conn
        end
      }
    }
  end

  def execute job = Proc.new
    promise = Promise.new job
    @queue << promise
    promise
  end

  def shutdown
    @size.times { execute { |conn| conn.shutdown } }
    @size.times { @queue << nil }
    @pool.each(&:join)
  end
end

uri = URI 'http://gatherer.wizards.com/Pages/Card/Details.aspx?multiverseid=100'
web_executor = ThreadExecutor.new 1

#promise = executor.execute do |conn|
#  response = conn.request uri
#  doc = Nokogiri.HTML response.body
#  node = doc.at_css('#ctl00_ctl00_ctl00_MainContent_SubContent_SubContent_cardImage')
#  conn.request(uri + URI(node['src'])).body
#end

class CardQuery
  BASE = 'http://gatherer.wizards.com/Pages/Card/Details.aspx?'

  attr_reader :body, :id

  def initialize id
    @id   = id
    @url  = URI(BASE + "multiverseid=#{id}")
    @body = nil
    @doc  = nil
  end

  def call conn
    @body = conn.request(@url).body
    @doc = Nokogiri.HTML @body
    self
  end

  def save!
    dir = File.join(DEST, @id.to_s)
    FileUtils.mkdir_p dir
    File.open(File.join(dir, 'page.html'), 'w') do |f|
      f.write @body
    end
  end
end

class CardImageQuery
  BASE = 'http://gatherer.wizards.com/Handlers/Image.ashx?'

  attr_reader :body, :id

  def initialize id
    @id   = id
    @url  = URI(BASE + "multiverseid=#{id}&type=card")
    @body = nil
  end

  def call conn
    @body = conn.request(@url).body
    self
  end

  def save!
    dir = File.join(DEST, @id.to_s)
    FileUtils.mkdir_p dir
    File.open(File.join(dir, 'card.jpg'), 'w') do |f|
      f.write @body
    end
  end
end

class SetQuery < Struct.new(:name, :page)
  BASE = 'http://gatherer.wizards.com/Pages/Search/Default.aspx?'
  def initialize name, page = 0
    super
    @body = nil
    @doc = nil
    @uri = URI(BASE + URI::DEFAULT_PARSER.escape("page=#{page}&set=[\"#{name}\"]"))
  end

  def call conn
    @body = conn.request(@uri).body
    @doc = Nokogiri.HTML @body
    self
  end

  def card_ids
    @doc.css('span.cardTitle > a').map { |node|
      url = @uri + URI(node['href'])
      params = Hash[url.query.split('&').map { |bit| bit.split('=') }]
      params['multiverseid'].to_i
    }
  end

  def next_page
    next_index = page + 1
    next_link = @doc.css('div.pagingControls > a').map { |link|
      @uri + URI(link['href'])
    }.find { |url|
      params = Hash[url.query.split('&').map { |bit| bit.split('=') }]
      params['page'].to_i == next_index
    }
    next_link && SetQuery.new(name, next_index)
  end
end

sets = web_executor.execute do |conn|
  uri = URI 'http://gatherer.wizards.com/Pages/Default.aspx'
  response = conn.request uri
  doc = Nokogiri.HTML response.body
  nodes = doc.css '#ctl00_ctl00_MainContent_Content_SearchControls_setAddText > option'
  nodes.reject { |node| node['value'].empty? }.map { |node| node['value'] }
end

promise = web_executor.execute SetQuery.new sets.value.first

card_id = promise.value.card_ids.first
[
  CardQuery.new(card_id),
  CardImageQuery.new(card_id),
].map { |job| web_executor.execute job }.each do |job|
  job.value.save!
end

#sets.value.map { |set_name|
#  web_executor.execute SetQuery.new set_name
#}

web_executor.shutdown
