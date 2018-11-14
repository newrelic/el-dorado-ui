require 'open3'

class ElDorado < Sinatra::Base

  configure :development do
    register Sinatra::Reloader
  end

  get '/' do
    haml :welcome
  end

  get '/catalog' do
    @yaml = yaml
    haml :catalog
  end

  get '/catalog/:category' do |category|
    nested = {}; nest = {}
    yaml.each do |k, v|
      if v['query'].nil?
        nest = nested[k] = {k => v}
      else
        nest[k] = v
      end
    end
    @yaml = nested[category] || yaml
    haml :catalog
  end

  get '/about' do
    haml :about
  end

  get '/label_name_detail' do
    query = queries['label_name_detail']
    query['alias'] = {'Name' => params['label'].downcase }
    run 'label_name_detail', query
    haml :query
  end

  get '/search' do
    comp = params['comp']||''
    regex = comp.downcase.gsub(/^|$| /, '.*')
    regex += "|#{comp.downcase.split('').join('.*[ _-]')}.*" if comp =~ /^[A-Z]+$/
    redirect "/schema_with_sources?regex=#{regex}"
  end

  get '/run' do
    tip = 'Ad hoc query and graph. With power comes responsibility.
      See docs [https://neo4j.com/docs/cypher-refcard/current/ cypher],
      [http://www.graphviz.org/content/dot-language dot]'
    unless params['query']
      body '400: No Query Provided'
      halt 400
    end
    query = deyamlify(params['query']).merge({'title' => 'Run Query', 'description' => tip})
    run 'run', query
    dotplot query
    visplot query
    haml :query
  end

  get '/smoketest' do
    @report = []
    count = 0
    queries.each do |slug, query|
      count += 1
      if inputs(query).length == 0 || !query['args'].nil? || !query['sample'].nil?
        start = Time.now
        run slug, query, eval_sample(query['sample'])||query['args']||{}
        # run slug, query
        duration = Time.now - start
        errors = @error ||
          (slug=='errors' ? @results.count!=0 && 'found' : @results.count==0 && 'no rows') ||
          (slug!='errors' && has_empty_column? && 'empty column') ||
          duration>1.5 && 'slow' ||
          ''
        @report << {
          slug: slug,
          query: query,
          duration: duration,
          rows: @results.count,
          columns: @columns,
          error: errors
        }
      else
        @report << {
          slug: slug,
          query: query,
          error: 'missing sample args or sample query'
        }
      end
      # break if count > 3
    end
    haml :smoketest
  end

  get '/download' do
    query = deyamlify(params['query']).merge({'title' => 'Run Query'})
    run 'run', query
    content_type :json
    JSON.pretty_generate decypher @results
  end

  get '/download/:query' do |slug|
    if queries[slug]
      run slug
    else
      body "404: query not found"
      halt 404
    end
    content_type :json
    JSON.pretty_generate decypher @results
  end

  get '/csv' do
    query = deyamlify(params['query']).merge({'title' => 'Run Query'})
    run 'run', query
    content_type :csv
    csv_generate decypher @results
  end

  get '/csv/:query' do |slug|
    if queries[slug]
      run slug
    else
      body "404: query not found"
      halt 404
    end
    content_type :csv
    csv_generate decypher @results
  end

  get '/dot' do
    query = deyamlify(params['query']).merge({'title' => 'Run Query'})
    run 'run', query
    dotify query['dot']
  end

  get '/dot/:query' do |slug|
    if (query = queries[slug]) && (dot = query['dot'])
      run slug
    else
      body "404: query not found"
      halt 404
    end
    dotify dot
  end


  post '/cypher' do
    request.body.rewind
    query = JSON.parse request.body.read
    query['params'] = {} if query['params'].nil?
    run 'api', query, query['params']
    content_type :json
    if @error.nil?
      JSON.pretty_generate decypher @results
    else
      status 400
      JSON.pretty_generate({error: @error})
    end
  end

  get '/:query' do |slug|
    if queries[slug]
      run slug
      dotplot queries[slug]
    else
      body "<center><h1>404: query not found</h1>See <a href=/catalog>Catalog</a>"
      halt 404
    end
    haml :query
  end


  helpers do

    def eval_sample match
      return nil unless match

      result = neo4j.query(match)

      return_value = {}

      result.first.to_h.each do |k,v|
        return_value[k.to_s] = v
      end
      return return_value
    end

    def yamldef query, field
      return '' unless query[field]
      "#{field}: |\n" +
      query[field].split(/\n/).map{|line|"  #{line}\n"}.join('')
    end

    def yamlify query
      yamldef(query, 'query') +
      yamldef(query, 'dot')
    end

    def deyamlify string
      if string.split("\n")[0] == 'query: |'
        YAML.load(string)
      else
        {'query' => string}
      end
    end

    def csv_generate table
      cols = table[0].keys
      puts cols.inspect
      CSV.generate do |csv|
        csv << cols
        table.each do |row|
          csv << cols.map{|col|row[col]}
        end
      end
    end

    def decypher results
      results.to_a.map do |struct|
        decypher_row struct.to_h
      end
    end

    def decypher_row elem
      case elem
      when Hash then elem.inject({}) {|hash,(key, value)| hash[key] = decypher_row(value); hash}
      when Array then elem.map {|value| decypher_row(value)}
      when Neo4j::Server::CypherNode then elem.props
      when Neo4j::Server::CypherRelationship then elem.props
      else elem
      end
    end

    def quote string
      "\"#{string.gsub(/[ _-]+/,'\n')}\""
    end

    def dotsub buffer, key, value
      buffer
        .gsub("\"{#{key}}\"",quote(value))
        .gsub("{#{key}}",value.gsub("&", "&amp;"))
    end

    def interpolate_kv(buffer, key, val)
      if val.is_a? Array
        return val.map do |elem|
          interpolate_kv(buffer, key, elem)
        end.join("\n")
      elsif val.is_a? Hash
        val.each do |subkey,subval|
          buffer = interpolate_kv(buffer, "#{key}.#{subkey}", subval)
        end
        return buffer
      else
        return dotsub(buffer, key, val.to_s)
      end
    end

    def add_base_to_urls(template)
      template.gsub(/URL="/, %(URL="#{request.base_url}))
    end

    def dotify template
      columns = @results.first.members
      output = []
      add_base_to_urls(template).lines.each do |line|
        line = line.gsub(/&/, '&amp;') # http://www.graphviz.org/doc/info/lang.html
        if (keywords = columns.select {|key| line.include? "{#{key}}"}).any?
          @results.each do |row|
            next unless keywords.all? {|key| row[key]}
            buffer = line.dup
            keywords.each do |key|
              buffer = interpolate_kv(buffer, key, row[key])
            end
            output << buffer
          end
        else
          output << line
        end
      end
      output.join("\n")
    end

    def dotplot query
      if @results.any? && (dot = query['dot'])
        @svg = pipe('dot -Tsvg', dotify(dot))
          .gsub(/<a /,'<a target="_top" ')
      end
    end

    def vistime string
      return Time.now.to_s if string.nil?
      return string.to_i if string.match /^\d+$/
      return string
    end

    def visplot query
      if @results.any?
        columns = @results.first.members.to_a
        puts columns.inspect
        return unless start = columns.find_index(:Start)
        return unless stop = columns.find_index(:Stop)
        return unless content = columns.find_index(:Content)
        @timeline = {data: [], groups: nil, options: {}}
        if group = columns.find_index(:Group)
          @timeline[:groups] = []
          @results.each do |row|
            id = row[group] || 'N/A'
            @timeline[:groups].push({id: id}) unless @timeline[:groups].include?(({id: id}))
          end
        end
        id = 0
        @timeline['data'] = @results.map do |row|
          id += 1
          {
            id: id,
            content: row[content],
            start: vistime(row[start]),
            end: vistime(row[stop]),
            group: (group ? row[group] : 'N/A')
          }
        end
      end
    end

    def has_empty_column?
      @columns.each_with_index do |value, col|
        return true unless @results.map{|row|row[col]}.any?
      end
      false
    end

    def inputs(query)
      query['query'].scan(/\{([a-z]+)\}/).flatten.sort.uniq
    end

    def variations(query)
      (query['variations']||{}).keys
    end

    def outputs(query)
      query['query'].scan(/as (\w+)\b/).flatten.map{|key|label(query,key)}.sort.uniq
    end

    def label(query, col)
      if @query['alias'] && @query['alias'][col.to_s]
        @query['alias'][col.to_s].downcase
      else
        col.to_s.downcase
      end
    end

    def json text
      JSON.parse text
    rescue JSON::ParserError => e
      nil
    end

    def cypher(query)
      cypher = @query['query']
      (@query['variations']||[]).each do |k, v|
         if @params.include? k
         cypher.gsub! v['replace'], v['with']
        end
      end
      cypher
    end

    def run slug, query=nil, args=nil
      @query = query || queries[slug]
      @error = nil

      unless slug == 'api'
        # Prepare expected URL params
        expected = inputs(@query) + variations(@query)
        @params = (args||params).select{ |k,_| expected.include? k }
        @params.each { |k,v| @params[k] = v.sub(/-aMp-/,'&') }
      else
        @params = args
      end

      # Run the query variation
      begin
        @results = neo4j.query(cypher(@query), @params)
      rescue Exception => e
        @results = []
        @error = e.message
      end

      # Select targets for clicks by column
      if @results.first
        @columns = @results.first.members
        @targets = find_best_target slug
      else
        @columns = []
      end
    end

    def sample_args(query)
      URI.encode_www_form eval_sample(query['sample'])||query['args']||[]
    end

    def formatted_value(value, column, row=nil)
      if value.nil?
        ''
      elsif value.kind_of?(Array)
        value.map{|v| formatted_value(v, column, row)}.join("<br/>")
      elsif value.kind_of?(String) && value[0]=='[' and json(value)
        formatted_value json(value), column
      elsif value.kind_of?(String) && value.match(/^https?:/)
        link_to_url(value)
      elsif value.kind_of?(Hash) && value[:type] == "link"
        link_to_url(value)
      elsif value.kind_of?(Hash)
        preserve("<pre>#{value.map{|k,v|"#{k}: #{v}"}.join("\n")}</pre>")
      elsif value.kind_of? Neo4j::Server::CypherNode
        # http://www.rubydoc.info/github/neo4jrb/neo4j-core/Neo4j/Server/CypherNode
        preserve("<pre>#{value.props.map{|k,v|"#{k}: #{v}"}.join("\n")}</pre>")
      elsif value.kind_of?(Neo4j::Server::CypherRelationship)
        # http://www.rubydoc.info/github/neo4jrb/neo4j-core/Neo4j/Server/CypherNode
        preserve("<pre>#{value.props.map{|k,v|"#{k}: #{v}"}.join("\n")}</pre>")
      elsif @targets && !(@targets[column].nil? || @targets[column].empty?)
        link_to_targets(value, label(@query,column), @targets[column].keys.first)
      elsif column == :Node && !row.nil? && @columns.include?(:Label)
        link_to_label_detail(value, row[:Label])
      else
        value
      end
    end

    def link_to_url(value)
      target = value
      kind = case value
      when Hash then
        target = value[:href]
        value[:text]
      when /README/ then 'readme'
      when /docs.google.com/ then 'docs'
      when /\/wiki\// then 'wiki'
      when /\.md/ then 'doc'
      else 'site'
      end
      "<a href=\"#{target}\" target=_blank>#{kind}</a>"
    end

    def link_to_targets(value, label, target)
      %Q|<a href="/#{target}?#{label.downcase}=#{enc value}">#{value}</a>|
    end

    def link_to_label_detail(value, label)
      %Q|<a href="/label_name_detail?label=#{enc label.upcase}&name=#{enc value}">#{value}</a>|
    end

    def find_best_target slug
      places = queries.keys
      here = places.index slug
      forward = places.rotate here||0
      @columns.inject({}) do |res, col|
        want = label(@query,col)
        there = forward.index do |key|
          q = inputs(queries[key])
          (q.size == 1 and q.first == want) or
          (q.size == 0 and variations(queries[key]).include?(want))
        end
        if there
          slug_there = forward[there]
          targets = {slug_there => queries[slug_there]}
          res.update(col => targets)
        else
          res
        end
      end
    end

    def recommended
      if want = @params['type'] || @params['label']
        count = 0
        queries.each do |slug, query|
          if query['query'].match /:#{want}\b/ and inputs(query).empty?
            yield slug, query
            count += 1
          end
        break if count >= 3
        end
      end
    end

    def yaml
      @yaml ||= YAML.load_file('config/queries.yml')
    end

    def queries
      @queries ||= yaml.select{ |s,q| q['query']}
    end

    def neo4j
      @neo4j ||= Neo4j::Session.open(:server_db, ENV['GRAPHDBURL']||'http://neo4j:password@localhost:7474/')
    end

    def pipe cmd, input
      result = nil
      Open3.popen3(cmd) do |i, o, e, t|
        i.write input
        i.close
        # STDERR.puts e.read
        result = o.read
      end
      result
    end

    def enc(thing)
      return "" if thing.nil?
      return thing.collect { |c| URI.encode(c) } if thing.kind_of?(Array)
      CGI.escape(thing.to_s)
    end
  end
end
