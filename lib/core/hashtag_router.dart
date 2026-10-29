/// Reads hashtags in a question and sets the reply length.
/// #shortlist -> short bullet list, #paragraph -> one paragraph,
/// #explain -> step-by-step with example, #detail -> full long answer.
enum ReplyStyle { shortlist, paragraph, explain, detail }

class ReplyPlan {
  const ReplyPlan({
    required this.cleanText,
    required this.style,
    required this.maxTokens,
    required this.instruction,
  });

  /// The student's question with the hashtags removed.
  final String cleanText;

  /// null when no hashtag was used.
  final ReplyStyle? style;

  /// Generation limit for the answer.
  final int maxTokens;

  /// Extra instruction added to the system prompt for this turn.
  final String instruction;
}

class HashtagRouter {
  HashtagRouter._();

  static final _tagPattern =
      RegExp(r'(^|\s)#(shortlist|paragraph|explain|detail)\b', caseSensitive: false);

  static ReplyPlan parse(String input) {
    ReplyStyle? style;
    for (final m in _tagPattern.allMatches(input)) {
      style = switch (m.group(2)!.toLowerCase()) {
        'shortlist' => ReplyStyle.shortlist,
        'paragraph' => ReplyStyle.paragraph,
        'explain' => ReplyStyle.explain,
        _ => ReplyStyle.detail,
      };
    }
    var clean = input.replaceAll(_tagPattern, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) clean = input.trim();

    return switch (style) {
      ReplyStyle.shortlist => ReplyPlan(
          cleanText: clean,
          style: style,
          maxTokens: 160,
          instruction: 'Answer as a short list of at most five points. No introduction, no conclusion.',
        ),
      ReplyStyle.paragraph => ReplyPlan(
          cleanText: clean,
          style: style,
          maxTokens: 450,
          instruction: 'Answer in one clear paragraph of four to six sentences.',
        ),
      ReplyStyle.explain => ReplyPlan(
          cleanText: clean,
          style: style,
          maxTokens: 1400,
          instruction: 'Explain step by step. Define key words, give a worked example, and finish with a short summary.',
        ),
      ReplyStyle.detail => ReplyPlan(
          cleanText: clean,
          style: style,
          maxTokens: 2800,
          instruction: 'Give a complete, thorough answer that covers every part of the question, with examples and a summary.',
        ),
      null => ReplyPlan(
          cleanText: clean,
          style: null,
          maxTokens: 350,
          instruction: 'Keep the answer short and clear unless more detail is needed.',
        ),
    };
  }
}
