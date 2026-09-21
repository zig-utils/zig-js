// Frozen runtime growth workloads for #927. Source construction and parsing
// happen during benchmark selection; the measured function evaluates the same
// class AST once per logical job. Each subject has a control with the same class
// count and static-initializer work but no inherited private environment.

var privateEnvironmentSelected = null;

function selectPrivateEnvironmentDeep(depth, control) {
  var source = ["var checksum = 0;"];
  for (var index = 0; index < depth; index = index + 1) {
    source.push("class C" + index + " {");
    if (!control) source.push("#n" + index + " = " + index + ";");
    source.push("static inner = (checksum = checksum + " + (index + 1) + ",");
  }
  source.push("0");
  for (var close = 0; close < depth; close = close + 1) source.push(");}");
  source.push("return checksum;");
  privateEnvironmentSelected = new Function(source.join(""));
  return privateEnvironmentGrowth;
}

function selectPrivateEnvironmentSiblings(width, control) {
  var source = ["var checksum = 0; class Outer {"];
  if (!control) {
    for (var name = 0; name < width; name = name + 1)
      source.push("#n" + name + ";");
  }
  for (var index = 0; index < width; index = index + 1)
    source.push("static f" + index + " = (checksum = checksum + " + (index + 1) + ", class { g() { return 0; } });");
  source.push("} return checksum;");
  privateEnvironmentSelected = new Function(source.join(""));
  return privateEnvironmentGrowth;
}

function privateEnvironmentGrowth(jobs, lane) {
  var total = 0;
  for (var job = 0; job < jobs; job = job + 1)
    total = total + privateEnvironmentSelected() + lane;
  return total;
}

function benchmarkFunction(name) {
  if (name === "private_environment_deep_32") return selectPrivateEnvironmentDeep(32, false);
  if (name === "private_environment_deep_64") return selectPrivateEnvironmentDeep(64, false);
  if (name === "private_environment_deep_128") return selectPrivateEnvironmentDeep(128, false);
  if (name === "private_environment_deep_control_32") return selectPrivateEnvironmentDeep(32, true);
  if (name === "private_environment_deep_control_64") return selectPrivateEnvironmentDeep(64, true);
  if (name === "private_environment_deep_control_128") return selectPrivateEnvironmentDeep(128, true);
  if (name === "private_environment_siblings_256") return selectPrivateEnvironmentSiblings(256, false);
  if (name === "private_environment_siblings_512") return selectPrivateEnvironmentSiblings(512, false);
  if (name === "private_environment_siblings_1024") return selectPrivateEnvironmentSiblings(1024, false);
  if (name === "private_environment_siblings_control_256") return selectPrivateEnvironmentSiblings(256, true);
  if (name === "private_environment_siblings_control_512") return selectPrivateEnvironmentSiblings(512, true);
  if (name === "private_environment_siblings_control_1024") return selectPrivateEnvironmentSiblings(1024, true);
  throw new Error("unknown private-environment growth workload: " + name);
}
