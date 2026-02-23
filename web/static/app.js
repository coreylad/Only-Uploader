// Poll the /api/job/<id> endpoint for running jobs shown on the dashboard,
// and update only the affected table cells without a full page reload.
(function () {
  var runningRows = document.querySelectorAll('tr[data-job-id]');
  if (runningRows.length === 0) return;

  function updateRow(row) {
    var jobId = row.getAttribute('data-job-id');
    fetch('/api/job/' + jobId)
      .then(function (r) { return r.json(); })
      .then(function (job) {
        var statusCell = row.querySelector('.job-status');
        var linesCell  = row.querySelector('.job-lines');
        if (statusCell) {
          if (job.done) {
            statusCell.innerHTML = job.returncode === 0
              ? '<span class="badge success">Done ✓</span>'
              : '<span class="badge error">Error (' + job.returncode + ')</span>';
            row.removeAttribute('data-job-id'); // stop polling this row
          }
        }
        if (linesCell) {
          linesCell.textContent = job.lines ? job.lines.length : 0;
        }
      })
      .catch(function () { /* ignore transient fetch errors */ });
  }

  setInterval(function () {
    document.querySelectorAll('tr[data-job-id]').forEach(updateRow);
  }, 4000);
})();
