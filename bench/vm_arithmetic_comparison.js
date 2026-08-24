function representativeVmArithmeticNumber(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var left = ((job + lane) & 1023) + 0.25;
    var right = (job % 31) + 1;
    total = total + (left + right);
    total = total + (left - right);
    total = total + (left * right);
    total = total + (left / right);
    total = total + (left % right);
    total = total + (left ** 2);
    total = total + (left < right ? 1 : 0) + (left <= right ? 1 : 0);
    total = total + (left > right ? 1 : 0) + (left >= right ? 1 : 0);
    total = total + (left == right ? 1 : 0) + (left === right ? 1 : 0);
    total = total + ((job & right) + (job | right) + (job ^ right));
    total = total + ((job << (right & 7)) + (job >> (right & 7)) + (job >>> (right & 7)));
  }
  return total;
}

function representativeVmArithmeticBigInt(jobs, lane) {
  var value = BigInt(lane + 1);
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    value = ((value + 3n) * 5n - 7n) % 1000003n;
    total = total + Number((value ** 2n) % 1021n);
    total = total + Number((value & 1023n) ^ (value >> 3n));
  }
  return total;
}

function representativeVmArithmeticPolymorphic(jobs, lane) {
  var effects = 0;
  var coercive = {
    valueOf() {
      effects = effects + 1;
      return lane + 7;
    }
  };
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1) {
    var left;
    var right;
    if ((job & 3) === 0) {
      left = job;
      right = lane + 1;
    } else if ((job & 3) === 1) {
      left = "value-";
      right = job;
    } else if ((job & 3) === 2) {
      left = BigInt(job);
      right = 3n;
    } else {
      left = coercive;
      right = job;
    }
    var result = left + right;
    if (typeof result === "number") total = total + result;
    else if (typeof result === "bigint") total = total + Number(result % 997n);
    else total = total + result.length;
  }
  return total + effects * 1009;
}

function representativeVmArithmeticCoercion(jobs, lane) {
  var effects = 0;
  var total = 0;
  var ordinary = {
    valueOf() {
      effects = effects + 1;
      return lane + 11;
    }
  };
  var abrupt = {
    valueOf() {
      effects = effects + 1;
      throw 97;
    }
  };
  for (var job = 0; job < jobs; job = job + 1) {
    var left = (job & 7) === 7 ? abrupt : ordinary;
    try {
      total = total + (left - (job & 31));
    } catch (error) {
      total = total + error;
    }
  }
  return total + effects * 1009;
}

function benchmarkFunction(name) {
  if (name === "representative_vm_arithmetic_number") return representativeVmArithmeticNumber;
  if (name === "representative_vm_arithmetic_bigint") return representativeVmArithmeticBigInt;
  if (name === "representative_vm_arithmetic_polymorphic") return representativeVmArithmeticPolymorphic;
  if (name === "representative_vm_arithmetic_coercion") return representativeVmArithmeticCoercion;
  throw new Error("unknown VM arithmetic workload: " + name);
}
