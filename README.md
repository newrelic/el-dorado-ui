# El Dorado UI

This is a Sinatra app that provides a UI and canned queries for El Dorado.
Learn more about this project at http://ddd.ward.wiki.org/

## Running Locally

To get this app running locally:

~~~
gem install bundler
bundle install
bundle exec rackup
~~~

You can then visit the app at http://localhost:9292

We assume the `dot` command is available from [Graphviz](http://www.graphviz.org/).

If you are not running your own instance of Neo4J locally, you'll need to alter
the database connection string with the GRAPHDBURL environment variable.

~~~
GRAPHDBURL='http://neo4j:neo4j@example.com:7474/' bundler exec rackup -o '0.0.0.0'
~~~


## License

El Dorado UI is licensed under the __MIT License__.  See [MIT-LICENSE](https://github.com/newrelic/el-dorado-ui/blob/master/MIT-LICENSE) for full text.

## Contributions

You are welcome to send pull requests to us - however, by doing so you agree that you are granting New Relic a non-exclusive, non-revokable, no-cost license to use the code, algorithms, patents, and ideas in that code in our products if we so choose. You also agree the code is provided as-is and you provide no warranties as to its fitness or correctness for any purpose.
