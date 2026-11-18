import 'package:flutter_test/flutter_test.dart';
import 'package:studymate_ai/core/hashtag_router.dart';

void main() {
  test('detects explain and removes the tag', () {
    final p = HashtagRouter.parse('What is inertia #explain');
    expect(p.style, ReplyStyle.explain);
    expect(p.cleanText, 'What is inertia');
    expect(p.maxTokens, greaterThan(1000));
  });

  test('shortlist gives the smallest budget', () {
    final p = HashtagRouter.parse('#shortlist uses of copper');
    expect(p.style, ReplyStyle.shortlist);
    expect(p.maxTokens, lessThan(300));
  });

  test('no hashtag keeps the default', () {
    final p = HashtagRouter.parse('hello');
    expect(p.style, isNull);
    expect(p.cleanText, 'hello');
  });
}
