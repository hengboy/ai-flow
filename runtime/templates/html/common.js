(function () {
  'use strict';

  // Table column sort
  document.querySelectorAll('table[data-sortable]').forEach(function (table) {
    table.querySelectorAll('th').forEach(function (th, idx) {
      th.addEventListener('click', function () {
        var tbody = table.querySelector('tbody');
        if (!tbody) return;
        var rows = Array.from(tbody.querySelectorAll('tr'));
        var asc = th.classList.contains('sort-asc');
        table.querySelectorAll('th').forEach(function (h) { h.classList.remove('sort-asc', 'sort-desc'); });
        th.classList.add(asc ? 'sort-desc' : 'sort-asc');
        rows.sort(function (a, b) {
          var va = a.cells[idx].textContent.trim();
          var vb = b.cells[idx].textContent.trim();
          return asc ? vb.localeCompare(va) : va.localeCompare(vb);
        });
        rows.forEach(function (r) { tbody.appendChild(r); });
      });
    });
  });

  // Table search
  var searchInput = document.querySelector('input.table-search');
  if (searchInput) {
    var targetId = searchInput.getAttribute('data-target');
    var targetTable = document.getElementById(targetId);
    if (targetTable) {
      searchInput.addEventListener('input', function () {
        var q = searchInput.value.toLowerCase();
        targetTable.querySelectorAll('tbody tr').forEach(function (tr) {
          var show = tr.textContent.toLowerCase().indexOf(q) >= 0;
          tr.style.display = show ? '' : 'none';
        });
      });
    }
  }

  // Sidebar nav active tracking
  var sidebar = document.querySelector('.nav-sidebar');
  if (sidebar) {
    var links = sidebar.querySelectorAll('a[href^="#"]');
    var sections = [];
    links.forEach(function (a) {
      var id = a.getAttribute('href').slice(1);
      var el = document.getElementById(id);
      if (el) sections.push({ el: el, link: a });
    });
    function update() {
      var scrollY = window.scrollY + 80;
      var active = null;
      sections.forEach(function (s) {
        if (s.el.offsetTop <= scrollY) active = s;
      });
      links.forEach(function (l) { l.classList.remove('active'); });
      if (active) active.link.classList.add('active');
    }
    window.addEventListener('scroll', update, { passive: true });
    update();
  }
})();
