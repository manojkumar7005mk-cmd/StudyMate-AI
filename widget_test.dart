import 'package:flutter_test/flutter_test.dart';

import 'package:studymate_ai/services/planner_service.dart';

void main() {
  test('valid times are accepted and invalid ones rejected', () {
    expect(PlannerLogic.validTime('09:30'), isTrue);
    expect(PlannerLogic.validTime('25:00'), isFalse);
  });
}
