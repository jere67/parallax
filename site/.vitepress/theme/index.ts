import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme-without-fonts'
import '@fontsource-variable/instrument-sans'
import '@fontsource/instrument-serif/400.css'
import '@fontsource/instrument-serif/400-italic.css'
import '@fontsource-variable/jetbrains-mono'
import Layout from './Layout.vue'
import ApiExamples from './components/ApiExamples.vue'
import Param from './components/Param.vue'
import Fields from './components/Fields.vue'
import Cards from './components/Cards.vue'
import Card from './components/Card.vue'
import Steps from './components/Steps.vue'
import Pill from './components/Pill.vue'
import Figure from './components/Figure.vue'
import Icon from './components/Icon.vue'
import './style.css'

// The default theme supplies the Markdown styles, code groups, and local search; Layout.vue
// replaces its page shell with the docs layout (tabs over a sidebar, outline on the right).
export default {
  extends: DefaultTheme,
  Layout,
  enhanceApp({ app }) {
    app.component('ApiExamples', ApiExamples)
    app.component('Param', Param)
    app.component('Fields', Fields)
    app.component('Cards', Cards)
    app.component('Card', Card)
    app.component('Steps', Steps)
    app.component('Pill', Pill)
    app.component('Figure', Figure)
    app.component('Icon', Icon)
  }
} satisfies Theme
