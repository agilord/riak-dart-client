part of riak_test;

class LocalHttpTest {
  TestConfig config;
  riak.Client client;
  riak.Bucket bucket;

  LocalHttpTest(this.config) {
    this.client = new riak.Client.http(config.httpHost, config.httpPort);
    this.bucket = client.getBucket(config.bucket);
  }

  Future<riak.Response> deleteKey(String key) {
    if (config.keepData) {
      return new Future.value(new riak.Response(200, true));
    } else {
      return bucket.delete(key);
    }
  }

  File localFile(String relativePath) {
    return new File.fromPath(config.scriptPath.append(relativePath));
  }

  run() {
    group('Riak HTTP: ', () {

      test('simple run', () {
        Future f = client.listBuckets().toList()
            .then((buckets) {
              if (!config.skipDataCheck) {
                expect(buckets, hasLength(0));
              }
              return bucket.fetch("k1");
            })
            .then((response) {
              if (!config.skipDataCheck) {
                expect(response.success, false);
              }
              return bucket.store("k1", new riak.Content.json({"x":1}));
            })
            .then((response) {
              expect(response.success, true);
              return bucket.fetch("k1");
            })
            .then((response) {
              expect(response.success, true);
              riak.Object obj = response.result;
              expect(obj.content.asJson["x"], 1);
              return obj.store(new riak.Content.json({"x":2}));
            })
            .then((response) {
              expect(response.success, true);
              return bucket.listKeys().toList();
            })
            .then((keys) {
              if (!config.skipDataCheck) {
                expect(keys, hasLength(1));
                expect(keys[0], "k1");
              }
              expect(keys, contains("k1"));
              return bucket.fetch("k1");
            })
            .then((response) {
              expect(response.success, true);
              riak.Object obj = response.result;
              expect(obj.content.asJson["x"], 2);
              return obj.store(new riak.Content.json({"x":3}), returnBody: true);
            })
            .then((response) {
              expect(response.success, true);
              riak.Object obj = response.result;
              expect(obj.content.asJson["x"], 3);
              return obj.delete(); // testing delete, will not keep data
            })
            .then((response) {
              expect(response.success, true);
              return bucket.fetch("k1");
            })
            .then((response) {
              expect(response.success, false);
              return client.ping();
            })
            .then((response) {
              expect(response.success, true);
            });
        expect(f, completes);
      });

      test('test index store and query', () {
        Future f = bucket.fetch("k2")
            .then((response) {
              if (!config.skipDataCheck) {
                expect(response.success, false);
              }
              var index = new riak.IndexBuilder()
              ..addInt("index1", 2)
              ..addString("index2", "c");
            return bucket.store("k2",
                new riak.Content.json({"x":1}, index:index.build()));
          })
          .then((response) {
            expect(response.success, true);
            return bucket.getIntIndex("index1").queryRange(1, 2).toList();
          })
          .then((result) {
            expect(result, hasLength(1));
            expect(result[0], "k2");
            return bucket.getIntIndex("index1").queryRange(0, 1).toList();
          })
          .then((result) {
            expect(result, hasLength(0));
            return bucket.getStringIndex("index2").queryEquals("c").toList();
          })
          .then((result) {
            expect(result, hasLength(1));
            expect(result[0], "k2");
            return deleteKey("k2");
          })
          .then((response) {
            expect(response.success, true);
          });
        expect(f, completes);
      });

      test('binary file', () {
        Future f = bucket.fetch("k3")
            .then((response) {
              if (!config.skipDataCheck) {
                expect(response.success, false);
              }
              return bucket.store("k3",
                  new riak.Content.stream(
                      localFile("../lib/riak_client.dart").openRead(),
                      type:new ContentType("test", "binary")));
            })
            .then((response) {
              expect(response.success, true);
              return bucket.fetch("k3");
            })
            .then((response) {
              expect(response.success, true);
              riak.Object obj = response.result;
              expect(riak.MediaType.typeEquals(
                  obj.content.type, new ContentType("test", "binary")), true);
              return obj.content.asStream.toList();
            })
            .then((content) {
              expect(content, hasLength(
                  localFile("../lib/riak_client.dart").lengthSync()));
              expect(content,
                  localFile("../lib/riak_client.dart").readAsBytesSync());
              return deleteKey("k3");
            })
            .then((response) {
              expect(response.success, true);
            });
        expect(f, completes);
      });

      test('bucket props', () {
        Future f = bucket.fetch("k4")
            .then((response) {
              if (!config.skipDataCheck) {
                expect(response.success, false);
              }
              return bucket.store("k4", new riak.Content.text("abc123"));
            })
            .then((response) {
              expect(response.success, true);
              return bucket.getProps();
            })
            .then((props) {
              expect(props.allow_mult, false);
              return bucket.setProps(new riak.BucketProps(allow_mult:true));
            })
            .then((response) {
              expect(response.success, true);
              return bucket.getProps();
            })
            .then((props) {
              expect(props.allow_mult, true);
              return bucket.setProps(null); // reset
            })
            .then((response) {
              expect(response.success, true);
              return bucket.getProps();
            })
            .then((props) {
              expect(props.allow_mult, false);
              return deleteKey("k4");
            })
            .then((response) {
              expect(response.success, true);
            });
        expect(f, completes);
      });

      // We store a simplified Set<int> in the content body as text. The initial
      // value is just a single item (5), and in three parallel writes we add an
      // extra (2), (3, 7) and (8) separately. As we are using the same vclock
      // reference, these will cause Riak to create siblings.
      // On reading the value back, we will use a fetch-specific Resolver to
      // merge the values and check for (2, 3, 5, 7, 8). Production clients
      // should set the resolvers on the client or bucket level.
      test('conflicts', () {
        var vclock1;
        Future f = bucket.fetch("k5")
            .then((response) {
              if (!config.skipDataCheck) {
                expect(response.success, false);
              }
              return bucket.setProps(new riak.BucketProps(
                  allow_mult: true, last_write_wins: false));
            })
            .then((response) {
              expect(response.success, true);
              return bucket.store("k5",
                  new riak.Content.text("5"), returnBody: true);
            })
            .then((response) {
              expect(response.success, true);
              riak.Object obj = response.result;
              vclock1 = obj.vclock;
              expect(vclock1, isNotNull);
              return Future.wait([
                  obj.store(new riak.Content.text("2 5")),
                  obj.store(new riak.Content.text("3 5 7")),
                  obj.store(new riak.Content.text("5 8")),
                  ]);
            })
            .then((List<riak.Response> responses) {
              expect(responses.length, 3);
              expect(responses[0].success, true);
              expect(responses[1].success, true);
              expect(responses[2].success, true);
              return bucket.fetch("k5",
                  resolver: new riak.Resolver.merge((header, a, b) {
                    Set set = new Set();
                    set.addAll(a.asText.split(" "));
                    set.addAll(b.asText.split(" "));
                    List list = new List.from(set.map((s) => int.parse(s)));
                    return new riak.Content.text((list..sort()).join(" "));
                  }));
            })
            .then((response) {
              expect(response.success, true);
              riak.Object obj = response.result;
              expect(obj.vclock, isNotNull);
              expect(obj.vclock != vclock1, true);
              expect(obj.content.asText, "2 3 5 7 8");
              return deleteKey("k5");
            })
            .then((response) {
              expect(response.success, true);
              return bucket.setProps(null);
            })
            .then((response) {
              expect(response.success, true);
            });
        expect(f, completes);
      });
    });
  }
}